import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../state/app_state.dart';
import 'transfer_bar.dart';

/// Barres du bas, réunies de haut en bas : action en attente (presse-papiers ou extraction), lecteur réduit,
/// opération en cours. Elles partagent une surface `surfaceContainerHigh`, séparées par un trait, au-dessus de la
/// zone sûre ; rien n'est dessiné quand aucune n'a lieu d'être.
///
/// Le lecteur réduit et l'opération en cours valent pour toute l'application : [PlayerFrame] (`mini_player.dart`)
/// les pose sous le navigateur, donc sous tous les écrans, et se déclare par [DockHost]. Un écran n'y met alors que
/// son action en attente, qui se place juste au-dessus. Sans [DockHost] (écran monté seul), le dock montre aussi
/// l'opération en cours.
class BottomDock extends StatelessWidget {
  const BottomDock({super.key, required this.state, this.pending});

  final AppState state;

  /// Action en attente de l'écran (`ClipboardBar`), montrée tant qu'un presse-papiers ou une archive à extraire
  /// existe.
  final Widget? pending;

  @override
  Widget build(BuildContext context) {
    final hosted = DockHost.maybeOf(context) != null;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final bars = [
          if (pending != null && (state.clipboard != null || state.pendingExtract != null)) pending!,
          if (!hosted && state.transfer != null) TransferBar(state: state),
        ];
        // vide : la place de la barre de navigation d'Android, que le Scaffold retire du corps de l'écran
        if (bars.isEmpty) return SizedBox(height: MediaQuery.paddingOf(context).bottom);
        return DockSurface(children: bars);
      },
    );
  }
}

/// Surface commune des barres du bas : un trait au-dessus, un trait entre deux barres, la zone sûre en dessous.
/// Vide : rien du tout (ni marge, ni trait).
class DockSurface extends StatelessWidget {
  const DockSurface({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final c in children) ...[const Divider(height: 1, thickness: 1), c],
        ]),
      ),
    );
  }
}

/// Posé par le cadre de l'application, qui montre lui-même le lecteur réduit et l'opération en cours sous tous les
/// écrans ; [slot] prête ces barres à la coquille des modules.
class DockHost extends InheritedWidget {
  const DockHost({super.key, this.slot, required super.child});

  final DockSlot? slot;

  static DockHost? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<DockHost>();

  @override
  bool updateShouldNotify(DockHost oldWidget) => false;
}

/// Barres communes du cadre (lecteur réduit, opération en cours), prêtées à la coquille des modules (phase 16) : tant
/// qu'elle est à l'écran sans page par-dessus ([embedded]), elle les pose au-dessus de sa barre de navigation et le
/// cadre n'en montre aucune sous elle. Prévient ses auditeurs quand les barres ou leur place changent.
class DockSlot extends ChangeNotifier {
  DockSlot(this._bars);

  final List<Widget> Function() _bars;
  bool _embedded = false;
  bool _disposed = false;

  /// Barres à montrer, de haut en bas ; vide quand rien n'a lieu d'être.
  List<Widget> get bars => _bars();

  /// Vrai quand la coquille pose les barres elle-même.
  bool get embedded => _embedded;

  set embedded(bool v) {
    if (v == _embedded) return;
    _embedded = v;
    changed();
  }

  /// Les barres ont changé ; jamais pendant la construction d'une image (la notification attend sa fin).
  void changed() {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
