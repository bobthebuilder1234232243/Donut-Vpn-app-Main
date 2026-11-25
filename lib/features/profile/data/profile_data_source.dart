import 'package:drift/drift.dart';
import 'package:fpdart/fpdart.dart';
import 'package:donutclub/core/db/db.dart';
import 'package:donutclub/features/profile/data/profile_data_mapper.dart';
import 'package:donutclub/features/profile/model/profile_entity.dart';
import 'package:donutclub/features/profile/model/profile_sort_enum.dart';
import 'package:donutclub/utils/utils.dart';
import 'package:loggy/loggy.dart';

part 'profile_data_source.g.dart';

abstract interface class ProfileDataSource {
  Future<ProfileEntry?> getById(String id);
  Future<ProfileEntry?> getByUrl(String url);
  Future<ProfileEntry?> getByUrlExact(String url);
  Future<ProfileEntry?> getByUrlLoose(String url);
  Future<ProfileEntry?> getByName(String name);
  Future<ProfileEntry?> getByNameExact(String name);
  Future<String> upsert(ProfileEntity profile);
  Future<int> countDuplicateUrls();
  Stream<ProfileEntry?> watchActiveProfile();
  Stream<int> watchProfilesCount();
  Stream<List<ProfileEntry>> watchAll({required ProfilesSort sort, required SortMode sortMode});
  Future<void> insert(ProfileEntriesCompanion entry);
  Future<void> edit(String id, ProfileEntriesCompanion entry);
  Future<void> deleteById(String id, bool isActive);
}

Map<SortMode, OrderingMode> orderMap = {SortMode.ascending: OrderingMode.asc, SortMode.descending: OrderingMode.desc};

/// Canonical form used for profile identity: trimmed, lowercased scheme and host,
/// no trailing slashes. Query strings and fragments are preserved.
String normalizeProfileUrl(String url) {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return trimmed.replaceAll(RegExp(r'/+$'), '');
  }
  final path = uri.path.replaceAll(RegExp(r'/+$'), '');
  return uri.replace(scheme: uri.scheme.toLowerCase(), host: uri.host.toLowerCase(), path: path).toString();
}

@DriftAccessor(tables: [ProfileEntries])
class ProfileDao extends DatabaseAccessor<Db> with _$ProfileDaoMixin, InfraLogger implements ProfileDataSource {
  ProfileDao(super.db);

  @override
  Future<ProfileEntry?> getById(String id) async {
    return await (profileEntries.select()..where((tbl) => tbl.id.equals(id))).getSingleOrNull();
  }

  @override
  Future<ProfileEntry?> getByUrl(String url) => getByUrlExact(url);

  /// Identity lookup for a remote profile: exact match on the stored URL or on its
  /// normalized form. Never a substring match - the old LIKE lookup made the same
  /// link look "new" and produced a second profile (then "Singapore711").
  @override
  Future<ProfileEntry?> getByUrlExact(String url) async {
    final normalized = normalizeProfileUrl(url);
    return await (select(profileEntries)
          ..where((tbl) => tbl.url.equals(url) | tbl.url.equals(normalized))
          ..limit(1))
        .getSingleOrNull();
  }

  /// Tolerant lookup for rows stored before URLs were normalized. Comparison is
  /// done in Dart so no LIKE wildcard inside the URL can widen the match.
  @override
  Future<ProfileEntry?> getByUrlLoose(String url) async {
    final target = normalizeProfileUrl(url);
    final rows = await (select(profileEntries)..where((tbl) => tbl.url.isNotNull())).get();
    for (final row in rows) {
      final candidate = row.url;
      if (candidate == null) continue;
      if (normalizeProfileUrl(candidate) == target || candidate.contains(url)) return row;
    }
    return null;
  }

  @override
  Future<ProfileEntry?> getByName(String name) => getByNameExact(name);

  @override
  Future<ProfileEntry?> getByNameExact(String name) async {
    return await (select(profileEntries)
          ..where((tbl) => tbl.name.equals(name))
          ..limit(1))
        .getSingleOrNull();
  }

  @override
  Stream<ProfileEntry?> watchActiveProfile() {
    return (profileEntries.select()
          ..where((tbl) => tbl.active.equals(true))
          ..limit(1))
        .watchSingleOrNull()
        .distinct();
  }

  @override
  Stream<int> watchProfilesCount() {
    final count = profileEntries.id.count();
    return (profileEntries.selectOnly()..addColumns([count])).map((exp) => exp.read(count)!).watchSingle().distinct();
  }

  @override
  Stream<List<ProfileEntry>> watchAll({required ProfilesSort sort, required SortMode sortMode}) {
    return (profileEntries.select()..orderBy([
          (tbl) => OrderingTerm(expression: tbl.active, mode: OrderingMode.desc),
          (tbl) {
            final trafficRatio = (tbl.download + tbl.upload) / tbl.total;
            final isExpired = tbl.expire.isSmallerOrEqualValue(DateTime.now());
            return OrderingTerm(
              expression:
                  (trafficRatio.isNull() | trafficRatio.isSmallerThanValue(1)) &
                  (isExpired.isNull() | isExpired.equals(false)),
              mode: OrderingMode.desc,
            );
          },
          switch (sort) {
            ProfilesSort.name => (tbl) => OrderingTerm(expression: tbl.name, mode: orderMap[sortMode]!),
            ProfilesSort.lastUpdate => (tbl) => OrderingTerm(expression: tbl.lastUpdate, mode: orderMap[sortMode]!),
          },
        ]))
        .watch();
  }

  @override
  Future<void> insert(ProfileEntriesCompanion entry) async {
    await transaction(() async {
      if (entry.active.present && entry.active.value) {
        await update(profileEntries).write(const ProfileEntriesCompanion(active: Value(false)));
      }
      // No name mangling here. Identity is resolved by upsert(), which reuses an
      // existing row instead of appending a random digit ("Singapore711").
      await into(profileEntries).insert(entry);
    });
  }

  /// Insert-or-update by identity, in one transaction.
  ///
  /// remote -> normalized URL, local -> normalized name. An existing row keeps its
  /// id, its `active` flag and its stored name unless a [UserOverride] supplies a
  /// new one. Only genuinely new rows get a deterministic "name (2)" suffix.
  @override
  Future<String> upsert(ProfileEntity profile) async {
    return transaction(() async {
      final isRemote = profile is RemoteProfileEntity;
      final name = profile.map(remote: (rp) => rp.name, local: (lp) => lp.name);
      final active = profile.map(remote: (rp) => rp.active, local: (lp) => lp.active);
      final id = profile.map(remote: (rp) => rp.id, local: (lp) => lp.id);
      final userOverride = profile.map(remote: (rp) => rp.userOverride, local: (lp) => lp.userOverride);

      final existing = isRemote
          ? await getByUrlExact((profile as RemoteProfileEntity).url)
          : await getByNameExact(name);
      final sameKind =
          existing != null && existing.type == (isRemote ? ProfileType.remote : ProfileType.local);

      if (existing != null && sameKind) {
        if (active) {
          await update(profileEntries).write(const ProfileEntriesCompanion(active: Value(false)));
        }
        var updateEntry = profile.toUpdateEntry();
        if (userOverride == null) {
          // A refresh must never rename the user's profile.
          updateEntry = updateEntry.copyWith(name: const Value.absent());
        }
        await (update(profileEntries)..where((tbl) => tbl.id.equals(existing.id))).write(updateEntry);
        loggy.log(LogLevel.info, 'profile upsert updated in place: [${existing.id}]');
        return existing.id;
      }

      final uniqueName = await _uniqueName(name);
      if (active) {
        await update(profileEntries).write(const ProfileEntriesCompanion(active: Value(false)));
      }
      await into(profileEntries).insert(profile.toInsertEntry().copyWith(name: Value(uniqueName)));
      loggy.log(LogLevel.info, 'profile upsert inserted: [$id] as [$uniqueName]');
      return id;
    });
  }

  /// Deterministic disambiguation: "name", "name (2)", "name (3)"...
  Future<String> _uniqueName(String name) async {
    if (await getByNameExact(name) == null) return name;
    var index = 2;
    while (await getByNameExact('$name ($index)') != null) {
      index++;
    }
    return '$name ($index)';
  }

  /// Counts extra rows sharing a normalized URL. Reported only - existing bad rows
  /// are never rewritten or deleted.
  @override
  Future<int> countDuplicateUrls() async {
    final rows = await (select(profileEntries)..where((tbl) => tbl.url.isNotNull())).get();
    final seen = <String, int>{};
    for (final row in rows) {
      final url = row.url;
      if (url == null) continue;
      final key = normalizeProfileUrl(url);
      seen[key] = (seen[key] ?? 0) + 1;
    }
    var duplicates = 0;
    for (final count in seen.values) {
      if (count > 1) duplicates += count - 1;
    }
    return duplicates;
  }

  @override
  Future<void> edit(String id, ProfileEntriesCompanion entry) async {
    await transaction(() async {
      final profile = await (profileEntries.select()..where((tbl) => tbl.id.equals(id))).getSingleOrNull();
      if (profile == null) {
        loggy.log(LogLevel.info, 'profile with id : [$id] deleted');
        return;
      }
      if (entry.active.present && entry.active.value) {
        await update(profileEntries).write(const ProfileEntriesCompanion(active: Value(false)));
      }
      await (update(profileEntries)..where((tbl) => tbl.id.equals(id))).write(entry);
    });
  }

  @override
  Future<void> deleteById(String id, bool isActive) async {
    await transaction(() async {
      await (delete(profileEntries)..where((tbl) => tbl.id.equals(id))).go();

      if (isActive) {
        final profiles = await (profileEntries.select()..where((tbl) => tbl.id.equals(id).not())).get();
        if (profiles.isEmpty) return;
        final prof = profiles.first;
        await (update(
          profileEntries,
        )..where((tbl) => tbl.id.equals(prof.id))).write(const ProfileEntriesCompanion(active: Value(true)));
      }
    });
  }
}
