/// Brand colors for Notees mobile (Margin Green identity, `brand/` submodule).
///
/// Layer 1 is a monochrome base (the default). Layer 2 is an optional
/// functional accent (Advance Green or paper). Layer 3 is dynamic color,
/// supplied at runtime by the user's device.
library;

import 'package:flutter/material.dart';

/// Functional accent for Notees: Advance Green, the brand's annotation,
/// link, and active-state color.
const Color noteesAccent = Color(0xFF2E5E46);

/// Warm paper accent for a paper-like feel (the brand light ground).
const Color noteesAccentCream = Color(0xFFF7F4EC);
