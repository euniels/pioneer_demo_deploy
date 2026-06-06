import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class PioneerPathLogo extends StatelessWidget {
  const PioneerPathLogo({
    super.key,
    this.size = 32,
    this.variant = PioneerPathLogoVariant.defaultMark,
  });

  final double size;
  final PioneerPathLogoVariant variant;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      switch (variant) {
        PioneerPathLogoVariant.lightOnDark =>
          'assets/images/pioneerpath_logo_light.svg',
        PioneerPathLogoVariant.darkOnLight =>
          'assets/images/pioneerpath_logo_dark.svg',
        PioneerPathLogoVariant.defaultMark =>
          'assets/images/pioneerpath_logo.svg',
      },
      width: size,
      height: size,
      fit: BoxFit.contain,
    );
  }
}

enum PioneerPathLogoVariant { defaultMark, darkOnLight, lightOnDark }
