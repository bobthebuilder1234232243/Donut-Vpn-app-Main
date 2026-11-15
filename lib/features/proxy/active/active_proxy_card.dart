import 'package:donutclub/core/localization/translations.dart';
import 'package:donutclub/core/widget/shimmer_skeleton.dart';
import 'package:donutclub/features/connection/model/connection_status.dart';
import 'package:donutclub/features/connection/notifier/connection_notifier.dart';
import 'package:donutclub/features/proxy/active/active_proxy_notifier.dart';
import 'package:donutclub/features/proxy/active/ip_widget.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ActiveProxyFooter extends ConsumerWidget {
  const ActiveProxyFooter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(
      connectionNotifierProvider.select((value) => value.valueOrNull ?? const Disconnected()),
    );

    final activeProxy = ref.watch(activeProxyNotifierProvider.select((value) => value.valueOrNull));
    final ipInfo = ref.watch(ipInfoNotifierProvider);
    final t = ref.watch(translationsProvider).requireValue;

    // Refresh the public IP when the selected outbound changes, so the card
    // never keeps the previous server's IP after a reconnect.
    ref.listen(activeProxyNotifierProvider.select((value) => value.valueOrNull?.tag), (previous, next) {
      if (previous != null && next != null && previous != next) {
        ref.invalidate(ipInfoNotifierProvider);
      }
    });

    // Early return if required data is not available.
    if (connectionState != const Connected() || activeProxy == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final liveInfo = ipInfo.valueOrNull;
    final ip = (liveInfo != null && liveInfo.ip.isNotEmpty) ? liveInfo.ip : activeProxy.ipinfo.ip;
    final countryCode = (liveInfo != null && liveInfo.countryCode.isNotEmpty)
        ? liveInfo.countryCode
        : activeProxy.ipinfo.countryCode;
    final countryName = activeProxy.tagDisplay.isEmpty ? t.common.unknown : activeProxy.tagDisplay;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.secondary.withValues(alpha: .21),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          IPCountryFlag(countryCode: countryCode, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  label: t.pages.proxies.ipInfo.country,
                  child: Text(
                    countryName,
                    style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 4),
                if (ip.isNotEmpty)
                  Semantics(
                    label: t.pages.proxies.ipInfo.address,
                    child: Text(
                      ip,
                      style: theme.textTheme.bodyMedium,
                      textDirection: TextDirection.ltr,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                else if (ipInfo.isLoading)
                  const ShimmerSkeleton(widthFactor: .6, height: 14)
                else
                  Text(
                    t.pages.proxies.unknownIp,
                    style: theme.textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// class _StatsColumn extends HookConsumerWidget {
//   const _StatsColumn();

//   @override
//   Widget build(BuildContext context, WidgetRef ref) {
//     final t = ref.watch(translationsProvider).requireValue;
//     final stats = ref.watch(statsNotifierProvider).value;

//     return Directionality(
//       textDirection: TextDirection.values[(Directionality.of(context).index + 1) % TextDirection.values.length],
//       child: Flexible(
//         child: Column(
//           children: [
//             _InfoProp(
//               icon: FluentIcons.arrow_bidirectional_up_down_20_regular,
//               text: (stats?.downlinkTotal ?? 0).size(),
//               semanticLabel: t.stats.totalTransferred,
//             ),
//             const Gap(8),
//             _InfoProp(
//               icon: FluentIcons.arrow_download_20_regular,
//               text: (stats?.downlink ?? 0).speed(),
//               semanticLabel: t.stats.speed,
//             ),
//           ],
//         ),
//       ),
//     );
//   }
// }

// class _InfoProp extends StatelessWidget {
//   const _InfoProp({
//     required this.icon,
//     required this.text,
//     this.semanticLabel,
//   });

//   final IconData icon;
//   final String text;
//   final String? semanticLabel;

//   @override
//   Widget build(BuildContext context) {
//     return Semantics(
//       label: semanticLabel,
//       child: Row(
//         children: [
//           Icon(icon),
//           const Gap(8),
//           Flexible(
//             child: Text(
//               text,
//               style: Theme.of(context).textTheme.labelMedium?.copyWith(fontFamily: FontFamily.emoji),
//               overflow: TextOverflow.ellipsis,
//             ),
//           ),
//         ],
//       ),
//     );
//   }
// }
