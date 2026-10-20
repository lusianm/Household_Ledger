import 'package:flutter/material.dart';

/// Scale layout and text together while keeping pointer and dialog coordinates aligned.
class AppZoom extends StatelessWidget {
  final double scale;
  final Widget child;
  const AppZoom({super.key, required this.scale, required this.child});
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final size = Size(
        constraints.maxWidth / scale,
        constraints.maxHeight / scale,
      );
      return SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.fill,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: MediaQuery(
              data: media.copyWith(
                size: size,
                padding: media.padding / scale,
                viewPadding: media.viewPadding / scale,
                viewInsets: media.viewInsets / scale,
              ),
              child: child,
            ),
          ),
        ),
      );
    },
  );
}
