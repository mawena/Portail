import 'package:fluluks/src/bridge/fluluks_api.g.dart';

import 'fake_host_api.dart';

/// Faux pont peuplé pour les tests d'accessibilité, de mise en page, les tests dorés et les captures : téléphone,
/// carte SD, disque LUKS2 ouvert (et une partition verrouillée), favoris, dossier de 40 éléments variés, serveur
/// SFTP connecté.

const _t = 1760000000; // 2025-10-09

SourceMsg _src(String id, String kind, String label, {bool encrypted = false, String? key}) => SourceMsg(
      id: id,
      stableKey: key ?? id,
      kind: kind,
      label: label,
      totalBytes: 128000000000,
      freeBytes: 41000000000,
      readOnly: false,
      roReason: '',
      encrypted: encrypted,
    );

EntryMsg _file(String dir, String name, int size, {int age = 0}) =>
    EntryMsg(name: name, path: '${dir == '/' ? '' : dir}/$name', type: 'file', size: size, mtime: _t - age);

EntryMsg _dir(String dir, String name) =>
    EntryMsg(name: name, path: '${dir == '/' ? '' : dir}/$name', type: 'dir', size: 0, mtime: _t - 86400);

/// 40 éléments : dossiers, photos, vidéos, musique, textes, documents, archives, une application, un nom long.
List<EntryMsg> demoFolder(String dir) => [
      for (final d in ['DCIM', 'Documents', 'Download', 'Music', 'Movies', 'Pictures']) _dir(dir, d),
      for (var i = 1; i <= 10; i++) _file(dir, 'IMG_2025100$i.jpg', 3200000 + i * 1000, age: i * 3600),
      for (var i = 1; i <= 4; i++) _file(dir, 'Vacances $i.mp4', 180000000 * i, age: i * 86400),
      for (var i = 1; i <= 6; i++) _file(dir, 'Morceau $i.mp3', 7000000 + i, age: i * 7200),
      for (var i = 1; i <= 5; i++) _file(dir, 'notes-$i.txt', 1200 * i, age: i * 600),
      for (final n in ['Facture.pdf', 'Rapport annuel.docx', 'Budget.xlsx']) _file(dir, n, 420000, age: 172800),
      for (final n in ['Sauvegarde.zip', 'Photos.tar.gz', 'Sources.7z']) _file(dir, n, 950000000, age: 259200),
      _file(dir, 'Portail.apk', 41000000, age: 3600),
      _file(dir, 'Un nom de fichier vraiment très long pour voir comment il se coupe.pdf', 1000, age: 60),
      _file(dir, 'LISEZ-MOI', 900, age: 60),
    ];

FakeHostApi demoApi() {
  final api = FakeHostApi()
    ..sources = [
      _src('phone', 'phone', 'Téléphone'),
      _src('sd:1', 'removable', 'Carte SD'),
      _src('v1', 'disk', 'Données', encrypted: true, key: 'disk:uuid-1'),
      _src('remote:s1', 'remote', 'Maison'),
    ]
    ..disks = [
      disk([
        part(index: 1, size: 64000000000, label: 'Données', volumeId: 'v1'),
        part(index: 2, size: 64000000000, label: 'Archives'),
      ]),
    ]
    ..volumes = [volume()]
    ..favorites = [
      FavoriteMsg(key: 'phone', path: '/DCIM', label: 'DCIM', sourceId: 'phone'),
      FavoriteMsg(key: 'disk:uuid-1', path: '/Projets', label: 'Projets', sourceId: 'v1'),
    ]
    ..servers = [
      RemoteServerMsg(
        id: 's1',
        protocol: 'sftp',
        name: 'Maison',
        host: '192.168.0.10',
        port: 22,
        user: 'charles',
        startPath: '/home/charles',
        remember: true,
        hostKey: 'SHA256:3b6Wq1i0yH1tqVQm0zZ8m2u4b0d7mX2b5hYw1n7g9aE',
        hasPassword: true,
        connected: true,
      ),
    ]
    ..dirs['phone'] = {'/': demoFolder('/'), '/DCIM': demoFolder('/DCIM')}
    ..dirs['v1'] = {'/': demoFolder('/')}
    ..filters['photos'] = [
      for (var i = 1; i <= 9; i++)
        FilterItemMsg(sourceId: i.isEven ? 'sd:1' : 'phone', path: '/DCIM/IMG_$i.jpg', name: 'IMG_$i.jpg', size: 3200000, mtime: _t),
    ]
    ..trash['phone'] = [
      TrashItemMsg(id: 't1', name: 'Ancien.pdf', originalPath: '/Documents/Ancien.pdf', deletedAt: _t * 1000, size: 230000, isDir: false),
      TrashItemMsg(id: 't2', name: 'Brouillons', originalPath: '/Brouillons', deletedAt: (_t - 86400) * 1000, size: 1200000, isDir: true),
    ]
    ..texts['/notes-1.txt'] = TextFileMsg(text: 'Liste des courses\r\n- pain\r\n- café\r\n', bom: true, crlf: true, mtime: _t, size: 40)
    ..searchResult = ((q) => SearchResultMsg(entries: demoFolder('/DCIM').where((e) => e.type == 'file').take(8).toList(), truncated: false));
  return api;
}

/// Analyse de démonstration du téléphone (phase 16) : arbre à plat, racine 0, place des dossiers = somme de leur
/// contenu, part hors analyse (-1) et contenu résumé (-2 pour la racine).
List<AnalysisNodeMsg> demoAnalysisTree() {
  const mib = 1 << 20;
  final specs = <(int, int, String, String, int)>[
    // (id, parent, nom, nature, place propre)
    (1, 0, 'DCIM', 'dir', 4096),
    (2, 1, 'Camera', 'dir', 4096),
    (3, 2, 'VID_20251009.mp4', 'file', 2400 * mib),
    (4, 2, 'IMG_0001.jpg', 'file', 6 * mib),
    (5, 2, 'IMG_0002.jpg', 'file', 5 * mib),
    (6, 0, 'Movies', 'dir', 4096),
    (7, 6, 'Vacances.mkv', 'file', 1800 * mib),
    (8, 0, 'Download', 'dir', 4096),
    (9, 8, 'Ubuntu.iso', 'file', 900 * mib),
    (10, 8, 'facture.pdf', 'file', 300 * 1024),
    (11, 0, 'Music', 'dir', 4096),
    (12, 11, 'Album', 'dir', 4096),
    (13, 12, 'piste-01.flac', 'file', 40 * mib),
    (14, 0, 'Android', 'dir', 4096),
    (15, 14, 'data', 'inaccessible', 0),
    (-2, 0, '', 'others', 3 * mib),
    (-1, 0, 'Applications, système et dossiers protégés', 'unscanned', 9000 * mib),
  ];
  final nodes = <int, AnalysisNodeMsg>{
    0: AnalysisNodeMsg(
        id: 0, parent: -1, name: '', path: '/', kind: 'dir', alloc: 0, apparent: 0, items: 0, mtime: _t,
        hasChildren: true, complete: true, depth: 0),
  };
  String pathOf(int parent, String name) => parent == 0 ? '/$name' : '${nodes[parent]!.path}/$name';
  for (final (id, parent, name, kind, size) in specs) {
    nodes[id] = AnalysisNodeMsg(
        id: id,
        parent: parent,
        name: name,
        path: id < 0 ? '/' : pathOf(parent, name),
        kind: kind,
        alloc: size,
        apparent: size,
        items: kind == 'others' ? 12 : 0,
        mtime: _t - id * 3600,
        hasChildren: specs.any((s) => s.$2 == id),
        complete: true,
        depth: 0);
    for (var p = parent; p >= 0; p = p == 0 ? -1 : nodes[p]!.parent) {
      nodes[p]!
        ..alloc += size
        ..apparent += size
        ..items += 1 + nodes[id]!.items;
    }
  }
  return nodes.values.toList();
}
