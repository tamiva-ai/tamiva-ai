import 'package:flutter/material.dart';

import '../data/pricing_plans.dart';
import '../services/api_client.dart';
import '../services/payment_service.dart';
import '../theme/tamiva_theme.dart';
import '../widgets/hero_scaffold.dart';
import '../widgets/logout_action.dart';

/// Three-plan pricing screen. Clean and minimal — no badges, no
/// animations, no marketing copy. Each plan is a card with its name,
/// price, a single subtitle line, a feature list, and a "Buy Now" CTA.
///
/// On Buy Now we kick off the Razorpay checkout for the chosen plan.
/// Successful purchases flip the user's tier server-side and the
/// caller can pop this screen to reveal the now-unlocked dashboard.
class PricingScreen extends StatefulWidget {
  final ApiClient apiClient;
  final String userEmail;
  final String userPhone;

  const PricingScreen({
    super.key,
    required this.apiClient,
    this.userEmail = '',
    this.userPhone = '',
  });

  @override
  State<PricingScreen> createState() => _PricingScreenState();
}

class _PricingScreenState extends State<PricingScreen> {
  String? _submittingPlan;
  String? _error;

  Future<void> _buy(PricingPlan plan) async {
    if (_submittingPlan != null) return;
    setState(() {
      _submittingPlan = plan.id;
      _error = null;
    });
    final result = await PaymentService.startProCheckout(
      api: widget.apiClient,
      plan: plan.id,
      contactEmail: widget.userEmail,
      contactPhone: widget.userPhone,
    );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _submittingPlan = null);
    if (result.ok) {
      messenger.showSnackBar(
        SnackBar(content: Text("You're now on the ${plan.name} plan.")),
      );
      Navigator.of(context).pop(true);
      return;
    }
    if (result.cancelled) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Checkout cancelled.')),
      );
      return;
    }
    setState(() => _error = result.message ?? 'Checkout failed.');
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return HeroBannerScaffold(
      heroAsset: 'assets/hero/brand_assets.png',
      title: 'Choose a plan',
      actions: [LogoutAction(apiClient: widget.apiClient)],
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            const SizedBox(height: 8),
            Text(
              'Pick the plan that fits where your brand is today.',
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            for (final plan in PricingPlans.all) ...[
              _PlanCard(
                plan: plan,
                loading: _submittingPlan == plan.id,
                disabled: _submittingPlan != null && _submittingPlan != plan.id,
                onBuy: () => _buy(plan),
              ),
              const SizedBox(height: 16),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: TamivaColors.error,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'Domain registration and hosting subscription charges may apply separately.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: TamivaColors.textFaint,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final PricingPlan plan;
  final bool loading;
  final bool disabled;
  final VoidCallback onBuy;

  const _PlanCard({
    required this.plan,
    required this.loading,
    required this.disabled,
    required this.onBuy,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: TamivaColors.surface,
        border: Border.all(color: TamivaColors.divider),
        borderRadius: BorderRadius.circular(TamivaRadii.md),
      ),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(plan.name, style: textTheme.headlineMedium),
          const SizedBox(height: 4),
          Text(plan.tagline, style: textTheme.bodyMedium),
          const SizedBox(height: 16),
          Text(
            plan.priceDisplay,
            style: textTheme.displayMedium?.copyWith(
              color: TamivaColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 14),
          for (final feature in plan.features) ...[
            _FeatureRow(text: feature),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 6),
          SizedBox(
            height: 48,
            child: GradientCtaButton(
              onPressed: (disabled || loading) ? null : onBuy,
              loading: loading,
              child: Text('Buy Now · ${plan.priceDisplay}'),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final String text;
  const _FeatureRow({required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Icon(Icons.check, size: 14, color: TamivaColors.gold),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: TamivaColors.textPrimary,
                ),
          ),
        ),
      ],
    );
  }
}