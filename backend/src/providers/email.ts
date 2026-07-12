/**
 * Minimal Resend integration for transactional email. If RESEND_API_KEY
 * is unset (or delivery fails), the message is logged to console so codes
 * can still be recovered from Railway logs during development.
 *
 * Set these env vars on Railway to send real email:
 *   RESEND_API_KEY  - obtain at https://resend.com/api-keys
 *   RESEND_FROM     - e.g. "Tamiva <noreply@yourdomain.com>". Sender
 *                     domain must be verified in Resend. During dev
 *                     leave unset and Resend's onboarding@resend.dev
 *                     works for delivery to your own email only.
 */
export async function sendPasswordResetEmail(
  to: string,
  code: string,
): Promise<void> {
  const apiKey = process.env.RESEND_API_KEY;
  const from = process.env.RESEND_FROM || "Tamiva <onboarding@resend.dev>";

  if (!apiKey) {
    console.log(`[email:fallback] Password reset code for ${to}: ${code}`);
    return;
  }

  const html = `
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:520px;margin:0 auto;padding:32px 24px;color:#1a1a1a;">
      <h1 style="font-size:24px;font-weight:600;margin:0 0 12px;">Reset your Tamiva password</h1>
      <p style="font-size:15px;line-height:1.5;color:#555;margin:0 0 24px;">
        Someone (hopefully you) asked to reset the password for this account.
        Enter this code in the app to continue:
      </p>
      <div style="background:#f8f5eb;border:1px solid #d4a72c;border-radius:12px;padding:20px;text-align:center;letter-spacing:8px;font-size:32px;font-weight:700;color:#8b1a2a;margin:0 0 24px;">
        ${code}
      </div>
      <p style="font-size:13px;color:#888;margin:0;">
        This code expires in 15 minutes. If you didn't request a reset, you can ignore this email.
      </p>
    </div>
  `;

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from,
        to: [to],
        subject: "Your Tamiva password reset code",
        html,
      }),
    });

    if (!res.ok) {
      const body = await res.text();
      console.error(`[email:resend] failed ${res.status}: ${body}`);
      // Also log the code so recovery is still possible from Railway logs.
      console.log(`[email:fallback] Password reset code for ${to}: ${code}`);
    }
  } catch (err) {
    console.error("[email:resend] threw:", err);
    console.log(`[email:fallback] Password reset code for ${to}: ${code}`);
  }
}
