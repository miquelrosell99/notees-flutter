import 'package:flutter/material.dart';

/// English-based [MaterialLocalizations] that overrides [firstDayOfWeekIndex].
///
/// The app is currently English-only, so using [DefaultMaterialLocalizations]
/// as the base preserves the existing strings while letting the calendar picker
/// honor the user's preferred first day of the week.
class _FirstDayOfWeekLocalizations extends DefaultMaterialLocalizations {
  _FirstDayOfWeekLocalizations(this._firstDayOfWeekIndex);

  final int _firstDayOfWeekIndex;

  @override
  int get firstDayOfWeekIndex => _firstDayOfWeekIndex;
}

/// Localizations delegate that serves [_FirstDayOfWeekLocalizations] with the
/// configured first day of week index.
class FirstDayOfWeekLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const FirstDayOfWeekLocalizationsDelegate(this.firstDayOfWeekIndex);

  final int firstDayOfWeekIndex;

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) async {
    return _FirstDayOfWeekLocalizations(firstDayOfWeekIndex);
  }

  @override
  bool shouldReload(covariant FirstDayOfWeekLocalizationsDelegate old) =>
      old.firstDayOfWeekIndex != firstDayOfWeekIndex;
}
