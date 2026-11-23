import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:donutclub/core/app_info/app_info_provider.dart';
import 'package:donutclub/core/localization/translations.dart';
import 'package:donutclub/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:donutclub/features/connection/notifier/connection_notifier.dart';
import 'package:donutclub/features/home/widget/connection_button.dart';
import 'package:donutclub/features/profile/notifier/active_profile_notifier.dart';
import 'package:donutclub/features/profile/widget/profile_tile.dart';
import 'package:donutclub/features/proxy/active/active_proxy_card.dart';
import 'package:donutclub/features/proxy/active/active_proxy_delay_indicator.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class HomePage extends HookConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    final activeProfile = ref.watch(activeProfileProvider);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset('assets/images/donut_logo.png', height: 24),
            const Gap(8),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: t.common.appTitle),
                  const TextSpan(text: " "),
                  const WidgetSpan(child: AppVersionLabel(), alignment: PlaceholderAlignment.middle),
                ],
              ),
            ),
          ],
        ),
        actions: const [Gap(8)],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Opacity(
              opacity: 0.09,
              child: Image.asset(
                'assets/images/world_map.png',
                fit: BoxFit.cover,
                color: theme.brightness == Brightness.dark ? Colors.white : Colors.grey,
                colorBlendMode: theme.brightness == Brightness.dark ? BlendMode.srcIn : BlendMode.srcATop,
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: switch (activeProfile) {
                    AsyncData(value: final profile?) => ProfileTile(
                      profile: profile,
                      isMain: true,
                      margin: EdgeInsets.zero,
                      color: theme.colorScheme.surfaceContainer,
                    ),
                    _ => const SizedBox.shrink(),
                  },
                ),
              ),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: const [ConnectionButton(), ActiveProxyDelayIndicator(), _StopAllRoutingButton()],
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const ActiveProxyFooter(),
                    if (ref.watch(hasAnyProfileProvider).value ?? false)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Material(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                          ),
                          child: InkWell(
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(16),
                              topRight: Radius.circular(16),
                            ),
                            onTap: () => ref.read(bottomSheetsNotifierProvider.notifier).showQuickSettings(),
                            child: Container(
                              height: 32,
                              padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(t.pages.home.quickSettings),
                                  const Gap(4),
                                  const Icon(Icons.arrow_drop_up_rounded, size: 16),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Panic control: stops the tunnel from ANY state (connecting, connected,
/// wedged or errored). Always enabled because forceDisconnect() is idempotent.
class _StopAllRoutingButton extends HookConsumerWidget {
  const _StopAllRoutingButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: FilledButton.icon(
        onPressed: () async {
          await ref.read(connectionNotifierProvider.notifier).forceDisconnect();
        },
        icon: const Icon(Icons.stop_circle_outlined, size: 20),
        label: const Text('Stop All Routing'),
        style: FilledButton.styleFrom(
          backgroundColor: theme.colorScheme.error,
          foregroundColor: theme.colorScheme.onError,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: const StadiumBorder(),
        ),
      ),
    );
  }
}

class AppVersionLabel extends HookConsumerWidget {
  const AppVersionLabel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final version = ref.watch(appInfoProvider).requireValue.presentVersion;
    if (version.isBlank) return const SizedBox();

    return Semantics(
      label: t.common.version,
      button: false,
      child: Container(
        decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(4)),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          version,
          textDirection: TextDirection.ltr,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
        ),
      ),
    );
  }
}
