import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:donutclub/core/haptic/haptic_service.dart';
import 'package:donutclub/core/localization/translations.dart';
import 'package:donutclub/core/model/constants.dart';
import 'package:donutclub/core/notification/in_app_notification_controller.dart';
import 'package:donutclub/core/preferences/general_preferences.dart';
import 'package:donutclub/core/router/dialog/dialog_notifier.dart';
import 'package:donutclub/features/connection/data/connection_data_providers.dart';
import 'package:donutclub/features/connection/data/connection_repository.dart';
import 'package:donutclub/features/connection/model/connection_failure.dart';
import 'package:donutclub/features/connection/model/connection_status.dart';
import 'package:donutclub/features/profile/model/profile_entity.dart';
import 'package:donutclub/features/profile/notifier/active_profile_notifier.dart';
import 'package:donutclub/donutcore/init_signal.dart';
import 'package:donutclub/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

part 'connection_notifier.g.dart';

@Riverpod(keepAlive: true)
class ConnectionNotifier extends _$ConnectionNotifier with AppLogger {
  @override
  Stream<ConnectionStatus> build() async* {
    if (Platform.isIOS) {
      await _connectionRepo.setup().mapLeft((l) {
        loggy.error("error setting up connection repository", l);
      }).run();
    }

    listenSelf((previous, next) async {
      if (previous == next) return;
      if (previous case AsyncData(:final value) when !value.isConnected) {
        if (next case AsyncData(value: final Connected _)) {
          await ref.read(hapticServiceProvider.notifier).heavyImpact();

          if (Platform.isAndroid && !ref.read(Preferences.storeReviewedByUser)) {
            if (await InAppReview.instance.isAvailable()) {
              InAppReview.instance.requestReview();
              ref.read(Preferences.storeReviewedByUser.notifier).update(true);
            }
          }
        }
      }
    });

    ref.listen(activeProfileProvider.select((value) => value.asData?.value), (previous, next) async {
      if (previous == null) return;
      final shouldReconnect = next == null || previous.id != next.id;
      if (shouldReconnect) {
        await reconnect(next);
      }
    });
    ref.watch(coreRestartSignalProvider);

    yield* _connectionRepo.watchConnectionStatus().doOnData((event) {
      if (event is Connected) {
        _failureSurfaced = false;
        _connectTimeoutTimer?.cancel();
      }
      if (event is Disconnected) {
        _connectTimeoutTimer?.cancel();
      }
      if (event case Disconnected(connectionFailure: final failure?)) {
        loggy.warning("connection failed: $failure");
        Future.microtask(() => ref.read(Preferences.startedByUser.notifier).update(false));
        // doOnData runs before this event becomes the new state, so this is the
        // state we are leaving: only a started service can have leaked a tunnel.
        final wasStarted = state.valueOrNull is Connecting || state.valueOrNull is Connected;
        // Only the status of an in-flight connect attempt is surfaced here; a
        // synchronous start failure is surfaced once by toggleConnection().
        if (state.valueOrNull is Connecting) _surfaceFailureOnce();
        // The engine can die after the OS tunnel is up (e.g. NO_AVAILABLE_PROXIES),
        // leaving VpnService/tun0 running with no core behind it: force a stop.
        if (wasStarted) unawaited(_teardownLeakedTunnel(failure));
      }
      loggy.info("connection status: ${event.format()}");
    });
  }

  ConnectionRepository get _connectionRepo => ref.read(connectionRepositoryProvider);

  // Caps the whole connect() call, including a slow VPN-permission dialog or hung gRPC start.
  static const _connectHardTimeout = Duration(seconds: 90);
  // Caps the wait for the status stream to confirm Connected after connect() accepted.
  static const _connectSoftTimeout = Duration(seconds: 30);
  Timer? _connectTimeoutTimer;
  bool _failureSurfaced = false;
  // Set while a failure-driven stop is in flight, so a failing Disconnected
  // emitted by that stop (or a duplicate status) cannot start another teardown.
  bool _tearingDown = false;

  /// Single owner of the engine-failure toast: shows it at most once per attempt.
  void _surfaceFailureOnce() {
    if (_failureSurfaced) return;
    _failureSurfaced = true;
    ref.read(inAppNotificationControllerProvider).showErrorToast(Constants.vpnEngineFailureMessage);
  }

  Future<void> mayConnect() async {
    if (state case AsyncData(:final value)) {
      if (value case Disconnected()) {
        try {
          await _connect();
        } catch (e) {
          loggy.warning("Ignored connection error in mayConnect: $e");
        }
      }
    }
  }

  Future<void> toggleConnection() async {
    try {
      final haptic = ref.read(hapticServiceProvider.notifier);
      if (_tearingDown) {
        loggy.warning("Ignoring connection attempt while tearing down leaked tunnel");
        return;
      }
      if (state case AsyncError()) {
        await haptic.lightImpact();
        await _connect();
      } else if (state case AsyncData(:final value)) {
        switch (value) {
          case Disconnected():
            await haptic.lightImpact();
            await ref.read(Preferences.startedByUser.notifier).update(true);
            await _connect();
          case Connected():
            // default:
            await haptic.mediumImpact();
            await ref.read(Preferences.startedByUser.notifier).update(false);
            await _disconnect();
          case Connecting():
            // Let the user cancel a connect that is stuck (e.g. NO_AVAILABLE_PROXIES).
            await haptic.mediumImpact();
            await ref.read(Preferences.startedByUser.notifier).update(false);
            await _disconnect();
          default:
            loggy.warning("switching status, debounce");
        }
      }
    } catch (e, stackTrace) {
      debugPrint('Connection failed: $e\n$stackTrace');
      if (!state.hasError) state = AsyncError(e, stackTrace);
      _surfaceFailureOnce();
    }
  }

  Future<void> reconnect(ProfileEntity? profile) async {
    if (state case AsyncData(:final value) when value == const Connected()) {
      if (profile == null) {
        loggy.info("no active profile, disconnecting");
        try {
          await _disconnect();
        } catch (e) {
          loggy.warning("Ignored connection error in reconnect: $e");
        }
        return;
      }
      loggy.info("active profile changed, reconnecting");
      await ref.read(Preferences.startedByUser.notifier).update(true);
      await _connectionRepo.reconnect(profile, ref.read(Preferences.disableMemoryLimit)).mapLeft((err) async {
        loggy.warning("error reconnecting", err);
        state = AsyncError(err, StackTrace.current);
        await ref
            .read(dialogNotifierProvider.notifier)
            .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      }).run();
    }
  }

  Future<void> abortConnection() async {
    if (state case AsyncData(:final value)) {
      switch (value) {
        case Connected() || Connecting():
          loggy.debug("aborting connection");
          try {
            await _disconnect();
          } catch (e) {
            loggy.warning("Ignored connection error in abortConnection: $e");
          }
        default:
      }
    }
  }

  /// Hard stop usable from ANY state: wedged Connecting, leaked tunnel, AsyncError.
  /// Stops the native service/core through the normal disconnect path and resets
  /// the status to Disconnected. Idempotent and never throws; shows no failure
  /// toast because this is a user-initiated clean stop.
  Future<void> forceDisconnect() async {
    _connectTimeoutTimer?.cancel();
    _failureSurfaced = false;
    await ref.read(Preferences.startedByUser.notifier).update(false);
    try {
      // Same native stop as _disconnect(); bounded so a wedged core cannot hang the UI.
      await _connectionRepo.disconnect().run().timeout(const Duration(seconds: 5));
    } catch (e) {
      loggy.warning("Ignored error while force disconnecting: $e");
    }
    state = const AsyncData(Disconnected());
  }

  final _singleStart = SingleCall();

  Future<void> _connect() async {
    await _singleStart.run(
      () async {
        _failureSurfaced = false;
        _connectTimeoutTimer?.cancel();
        await _connectThrottled();
      },
      onIgnored: () {
        loggy.debug("connect called while another connect/disconnect is still running, ignoring");
      },
    );
  }

  Future<void> _connectThrottled() async {
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) {
      loggy.info("no active profile, not connecting");
      return;
    }
    _failureSurfaced = false;
    ConnectionFailure? failure;
    try {
      final result = await _connectionRepo
          .connect(activeProfile, ref.read(Preferences.disableMemoryLimit))
          .run()
          .timeout(_connectHardTimeout);
      failure = result.fold<ConnectionFailure?>((err) => err, (_) => null);
    } on TimeoutException {
      loggy.warning("connect() hard timeout after ${_connectHardTimeout.inSeconds}s, aborting");
      await _abortStuckConnect();
      return;
    }
    if (failure == null) {
      // Core accepted the config; now guard only the wait for Connected.
      _connectTimeoutTimer?.cancel();
      _connectTimeoutTimer = Timer(_connectSoftTimeout, _onConnectTimeout);
      return;
    }

    _connectTimeoutTimer?.cancel();
    loggy.warning("error connecting", failure);
    if (failure.toString().contains("panic")) {
      await Sentry.captureException(Exception(failure.toString()));
    }
    await ref.read(Preferences.startedByUser.notifier).update(false);
    state = AsyncError(failure, StackTrace.current);
    // Surfaced once by toggleConnection()'s catch block.
    throw failure;
  }

  /// The core can die after the tunnel is established, so connect() succeeded but
  /// the status later turns into Disconnected(failure) while VpnService/tun0 is
  /// still up. Stop the native service the same way a normal disconnect does:
  /// core.stop() closes the VpnService file descriptor and stops the service.
  Future<void> _teardownLeakedTunnel(ConnectionFailure failure) async {
    if (_tearingDown) return;
    _tearingDown = true;
    _connectTimeoutTimer?.cancel();
    loggy.warning("force-tearing down leaked VPN tunnel after start failure: $failure");
    try {
      // Bound it: a dead core must never leave the UI waiting on the stop.
      final result = await _connectionRepo.disconnect().run().timeout(const Duration(seconds: 5));
      final stopFailure = result.fold<ConnectionFailure?>((err) => err, (_) => null);
      if (stopFailure != null) loggy.warning("error stopping leaked tunnel", stopFailure);
    } catch (e) {
      loggy.warning("Ignored connection error while tearing down leaked tunnel: $e");
    } finally {
      _tearingDown = false;
      await ref.read(Preferences.startedByUser.notifier).update(false);
    }
  }

  Future<void> _disconnect() async {
    _connectTimeoutTimer?.cancel();
    final result = await _connectionRepo.disconnect().run();
    final failure = result.fold<ConnectionFailure?>((err) => err, (_) => null);
    if (failure == null) return;

    loggy.warning("error disconnecting", failure);
    state = AsyncError(failure, StackTrace.current);
    // Surfaced once by toggleConnection()'s catch block.
    throw failure;
  }

  void _onConnectTimeout() {
    loggy.warning("connect timed out after ${_connectSoftTimeout.inSeconds}s, aborting");
    unawaited(_abortStuckConnect());
  }

  Future<void> _abortStuckConnect() async {
    if (state.valueOrNull is Connected) {
      _connectTimeoutTimer?.cancel();
      return;
    }
    try {
      // Bound the native stop so the timeout itself can never block the UI.
      // _disconnect() -> connectionRepo.disconnect() -> core.stop(), which closes
      // the VpnService file descriptor (tun0) exactly like a normal disconnect.
      await _disconnect().timeout(const Duration(seconds: 5));
    } catch (e) {
      loggy.warning("Ignored connection error in connect timeout: $e");
    }
    await ref.read(Preferences.startedByUser.notifier).update(false);
    if (state.valueOrNull is! Disconnected) {
      state = const AsyncData(Disconnected());
    }
    _surfaceFailureOnce();
  }
}

@Riverpod(keepAlive: true)
bool serviceRunning(Ref ref) {
  // ref.watch(coreRestartSignalProvider);
  return ref.watch(connectionNotifierProvider).valueOrNull?.isConnected ?? false;
}

class SingleCall {
  bool _running = false;

  Future<T> run<T>(Future<T> Function() task, {required T onIgnored}) async {
    if (_running) return onIgnored;

    _running = true;
    try {
      return await task();
    } finally {
      _running = false;
    }
  }
}
