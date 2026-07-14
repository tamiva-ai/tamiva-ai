import 'dart:async';
import 'dart:convert';

import 'package:razorpay_flutter/razorpay_flutter.dart';

import 'api_client.dart';

/// Outcome of a Pro checkout attempt.
class ProCheckoutResult {
  final bool ok;
  final bool cancelled;
  final String? tier;
  final String? message;

  const ProCheckoutResult._({
    required this.ok,
    this.cancelled = false,
    this.tier,
    this.message,
  });

  factory ProCheckoutResult.success(String tier) =>
      ProCheckoutResult._(ok: true, tier: tier);
  factory ProCheckoutResult.cancelled([String? message]) =>
      ProCheckoutResult._(ok: false, cancelled: true, message: message);
  factory ProCheckoutResult.failure(String message) =>
      ProCheckoutResult._(ok: false, message: message);
}

/// Runs the full Tamiva payment flow and resolves to a single
/// [ProCheckoutResult]. Wraps razorpay_flutter's callback API in a
/// [Completer] so callers can simply `await` it.
///
/// Flow: create order (backend) -> open Razorpay sheet -> on success,
/// verify the signature server-side (which flips the user to the
/// selected plan's tier).
///
/// v36 / S1.1: when the verify call fails after Razorpay already
/// charged the card, we re-query /payments/status so a webhook that
/// ran in the meantime resolves the user without manual intervention.
/// Previously the user saw "verification failed, contact support" even
/// though the webhook would have reconciled them.
///
/// v37: accepts a [plan] so any of the three pricing plans (launch /
/// pro / premium) can be bought through this flow. When [plan] is null
/// the server defaults to 'pro', preserving v36 single-tier behavior.
class PaymentService {
  static Future<ProCheckoutResult> startProCheckout({
    required ApiClient api,
    String? businessProfileId,
    String? idempotencyKey,
    String? plan,
    String contactEmail = '',
    String contactPhone = '',
  }) async {
    final RazorpayOrder order;
    try {
      order = await api.createRazorpayOrder(
        businessProfileId: businessProfileId,
        idempotencyKey: idempotencyKey,
        plan: plan,
      );
    } catch (e) {
      // Surface the real backend reason (e.g. "Payments aren't set up
      // yet", a Razorpay validation message, "User not found", or
      // "You're already on Tamiva Pro") instead of a blanket failure.
      return ProCheckoutResult.failure(_checkoutError(e));
    }

    final resolvedPlan = order.plan ?? plan ?? 'pro';
    final completer = Completer<ProCheckoutResult>();
    final razorpay = Razorpay();

    void finish(ProCheckoutResult result) {
      if (!completer.isCompleted) completer.complete(result);
      razorpay.clear();
    }

    razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS,
        (PaymentSuccessResponse resp) async {
      try {
        final tier = await api.verifyRazorpayPayment(
          orderId: resp.orderId ?? order.orderId,
          paymentId: resp.paymentId ?? '',
          signature: resp.signature ?? '',
        );
        finish(ProCheckoutResult.success(tier));
      } catch (_) {
        // Verify call failed but Razorpay already charged the card.
        // The webhook will reconcile within seconds; tell the user
        // we'll upgrade them shortly and refresh their tier.
        try {
          final refreshed = await api.refreshTier();
          if (refreshed != null && refreshed.tier != 'free') {
            finish(ProCheckoutResult.success(refreshed.tier));
            return;
          }
        } catch (_) {}
        finish(ProCheckoutResult.failure(
          'Payment received. Your $resolvedPlan plan is being confirmed — '
          'this usually takes a few seconds. Try again in a moment.',
        ));
      }
    });

    razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, (PaymentFailureResponse resp) {
      finish(ProCheckoutResult.cancelled(resp.message));
    });

    razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, (_) {});

    razorpay.open({
      'key': order.keyId,
      'order_id': order.orderId,
      'amount': order.amount,
      'currency': order.currency,
      'name': 'Tamiva',
      'description': 'Tamiva $resolvedPlan',
      'theme': {'color': '#D4A72C'},
      if (contactEmail.isNotEmpty || contactPhone.isNotEmpty)
        'prefill': {
          if (contactEmail.isNotEmpty) 'email': contactEmail,
          if (contactPhone.isNotEmpty) 'contact': contactPhone,
        },
    });

    return completer.future;
  }
}

/// Pulls the backend's `{"error": "..."}` message out of an
/// [ApiException] so checkout failures show the real reason (payments
/// not configured, a Razorpay validation error, already-Pro, etc.).
String _checkoutError(Object error) {
  if (error is ApiException) {
    try {
      final decoded = jsonDecode(error.body);
      if (decoded is Map && decoded['error'] is String) {
        final msg = (decoded['error'] as String).trim();
        if (msg.isNotEmpty && msg.length < 200) return msg;
      }
    } catch (_) {}
  }
  return "Couldn't start checkout. Try again.";
}
