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

/// Runs the full Tamiva Pro payment flow and resolves to a single
/// [ProCheckoutResult]. Wraps razorpay_flutter's callback API in a
/// [Completer] so callers can simply `await` it.
///
/// Flow: create order (backend) -> open Razorpay sheet -> on success,
/// verify the signature server-side (which flips the user to Pro).
class PaymentService {
  static Future<ProCheckoutResult> startProCheckout({
    required ApiClient api,
    String? userId,
    String? businessProfileId,
    String contactEmail = '',
    String contactPhone = '',
  }) async {
    final RazorpayOrder order;
    try {
      order = await api.createRazorpayOrder(
        userId: userId,
        businessProfileId: businessProfileId,
      );
    } catch (e) {
      // Surface the real backend reason (e.g. "Payments aren't set up
      // yet", a Razorpay validation message, "User not found", or
      // "You're already on Tamiva Pro") instead of a blanket failure.
      return ProCheckoutResult.failure(_checkoutError(e));
    }

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
          userId: order.userId,
          orderId: resp.orderId ?? order.orderId,
          paymentId: resp.paymentId ?? '',
          signature: resp.signature ?? '',
        );
        finish(ProCheckoutResult.success(tier));
      } catch (_) {
        finish(ProCheckoutResult.failure(
          'Payment received but verification failed. Please contact support.',
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
      'description': 'Tamiva Pro (monthly)',
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
