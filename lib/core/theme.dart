import 'dart:ui';
import 'package:flutter/material.dart';

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF0A84FF), // iOS system blue
    brightness: b,
    surface: dark ? const Color(0xFF000000) : const Color(0xFFF2F2F7),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 0),
    textTheme: Typography.material2021(platform: TargetPlatform.iOS)
        .black
        .apply(fontFamily: null),
  );
}

/// Frosted-glass container: blur + translucent fill + hairline border.
class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  const Glass(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(12),
      this.radius = 18});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: (dark ? Colors.white : Colors.white)
                .withOpacity(dark ? 0.08 : 0.65),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
                color: (dark ? Colors.white : Colors.black).withOpacity(0.08),
                width: 0.5),
          ),
          child: child,
        ),
      ),
    );
  }
}
