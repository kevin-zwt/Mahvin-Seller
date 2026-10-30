import 'dart:async';

import 'package:flutter/material.dart';

import '../../common/widgets/app_logo.dart';
import '../../core/app_info.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';

/// The branded launch screen shown while the app boots: gradient backdrop,
/// the Mahvin mark, the wordmark and a subtle progress bar. After a short
/// beat it cross-fades into the app shell.
class SplashPage extends StatefulWidget {
  const SplashPage({super.key, required this.next});

  final Widget next;

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  static const _holdDuration = Duration(milliseconds: 1400);
  static const _fadeDuration = Duration(milliseconds: 350);

  late final AnimationController _controller;
  late final Animation<double> _logoScale;
  late final Animation<double> _fade;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();
    _logoScale = Tween<double>(
      begin: 0.82,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
    _fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0, 0.6, curve: Curves.easeOut),
    );
    _timer = Timer(_holdDuration, _openNext);
  }

  void _openNext() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        transitionDuration: _fadeDuration,
        pageBuilder: (context, animation, secondaryAnimation) => widget.next,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: child,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: AppColors.hero),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const Positioned(
              top: -120,
              right: -90,
              child: _Glow(diameter: 320, opacity: 0.12),
            ),
            const Positioned(
              bottom: -140,
              left: -110,
              child: _Glow(diameter: 380, opacity: 0.08),
            ),
            SafeArea(
              child: Center(
                child: FadeTransition(
                  opacity: _fade,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppDimens.xl,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ScaleTransition(
                          scale: _logoScale,
                          child: Container(
                            padding: const EdgeInsets.all(AppDimens.sm),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.25),
                              ),
                            ),
                            child: const AppLogo(size: 104, showShadow: true),
                          ),
                        ),
                        const SizedBox(height: AppDimens.xl),
                        Text(
                          AppInfo.wordmark,
                          style: textTheme.headlineMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 4,
                          ),
                        ),
                        const SizedBox(height: AppDimens.sm),
                        Text(
                          AppInfo.tagline,
                          style: textTheme.bodySmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.8),
                            letterSpacing: 1.4,
                          ),
                        ),
                        const SizedBox(height: AppDimens.xxl),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(
                            AppDimens.radiusPill,
                          ),
                          child: SizedBox(
                            width: 120,
                            child: LinearProgressIndicator(
                              minHeight: 3,
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.22,
                              ),
                              valueColor: const AlwaysStoppedAnimation(
                                Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.diameter, required this.opacity});

  final double diameter;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: opacity),
        shape: BoxShape.circle,
      ),
    );
  }
}
