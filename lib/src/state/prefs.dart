import '../bridge/fluluks_api.g.dart';

/// Copie modifiée des préférences d'affichage : les écrans ne reconstruisent plus `ViewPrefsMsg` champ par champ
/// (un champ ajouté plus tard ne peut plus être oublié).
extension ViewPrefsCopy on ViewPrefsMsg {
  ViewPrefsMsg copyWith({String? sort, bool? ascending, bool? grid, bool? showHidden, bool? builtInViewers}) =>
      ViewPrefsMsg(
        sort: sort ?? this.sort,
        ascending: ascending ?? this.ascending,
        grid: grid ?? this.grid,
        showHidden: showHidden ?? this.showHidden,
        builtInViewers: builtInViewers ?? this.builtInViewers,
      );
}

/// Copie modifiée des préférences d'interface (thème, retours haptiques, bienvenue vue, terminal).
extension UiPrefsCopy on UiPrefsMsg {
  UiPrefsMsg copyWith({
    String? theme,
    bool? haptics,
    bool? welcomeSeen,
    int? terminalFontSize,
    bool? terminalSecure,
  }) =>
      UiPrefsMsg(
        theme: theme ?? this.theme,
        haptics: haptics ?? this.haptics,
        welcomeSeen: welcomeSeen ?? this.welcomeSeen,
        terminalFontSize: terminalFontSize ?? this.terminalFontSize,
        terminalSecure: terminalSecure ?? this.terminalSecure,
      );

  /// Taille du texte du terminal, bornée (13 par défaut).
  int get terminalFont => (terminalFontSize ?? terminalFontDefault).clamp(terminalFontMin, terminalFontMax);
}

const terminalFontDefault = 13;
const terminalFontMin = 8;
const terminalFontMax = 32;
