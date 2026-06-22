/// Fleet design-system colors for Notees mobile.
///
/// Layer 1 is a monochrome base. Layer 2 is the functional accent (sage green
/// for a productivity/notes app). Layer 3 is dynamic color, supplied at runtime
/// by the user's device.
library;

import 'package:flutter/material.dart';

/// Functional accent for Notees: calm sage green.
const Color noteesAccent = Color(0xFF5B7D5B);

/// Beige accent preset used in the settings accent picker.
const Color noteesAccentBeige = Color(0xFFE8DCC4);

/// Preserved legacy Kotlin-wrapper accent reference.
const Color noteesAccentLegacy = Color(0xFF404040);
