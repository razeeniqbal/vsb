import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// Posts "X moved up from the waiting list" to the club Telegram group.
//
// Called by the database (pg_net) right after the waiting list books someone in.
// The caller only says WHICH notification; the message is built here from the
// database, so this endpoint can't be used to send anything else, and each
// promotion is announced at most once (the row is claimed atomically).

// Public player app. Override with the SITE_URL function secret if the domain changes.
const SITE_URL = (Deno.env.get("SITE_URL") ?? "https://vsb.madebyrazeen.com").replace(/\/$/, "");
const HOLD_HOURS = 12;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const { notificationId } = await req.json();
    if (!notificationId || typeof notificationId !== "string") return json({ error: "notificationId is required" }, 400);

    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const { data: settings } = await admin.from("club_settings").select("whatsapp_group_notify").eq("id", 1).maybeSingle();
    if (!settings?.whatsapp_group_notify) return json({ skipped: "group notifications are off" });

    // Claim it: only a fresh waiting-list promotion that hasn't been announced yet.
    const since = new Date(Date.now() - 10 * 60_000).toISOString();
    const { data: claimed } = await admin
      .from("notifications")
      .update({ group_notified_at: new Date().toISOString() })
      .eq("id", notificationId)
      .eq("notification_type", "waitlist_promoted")
      .is("group_notified_at", null)
      .gte("created_at", since)
      .select("user_id, booking_id")
      .maybeSingle();
    if (!claimed?.booking_id) return json({ skipped: "nothing to announce" });

    const { data: booking } = await admin.from("bookings").select("total_amount, session_id").eq("id", claimed.booking_id).maybeSingle();
    const { data: profile } = await admin.from("profiles").select("short_name, full_name").eq("id", claimed.user_id).maybeSingle();
    const { data: session } = booking
      ? await admin.from("sessions").select("id, title, session_date").eq("id", booking.session_id).maybeSingle()
      : { data: null };
    if (!booking || !session) return json({ skipped: "booking or session missing" });

    const name = profile?.short_name || profile?.full_name || "Seorang pemain";
    const text =
      `🏐 ${session.title}\n\n` +
      `UPDATE: ${name} dah naik dari waiting list! 🎉\n` +
      `${name}, sila bayar RM${Number(booking.total_amount).toFixed(2)} & upload resit dalam ${HOLD_HOURS} jam. ` +
      `Kalau tak, slot akan diberi kepada orang seterusnya dalam waiting list.\n\n` +
      `Booking: ${SITE_URL}/sessions/${session.id}`;

    const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN");
    const chatId = Deno.env.get("TELEGRAM_CHAT_ID");
    if (!botToken || !chatId) {
      console.log("[Waitlist notify] Telegram not configured, logging only:", { notificationId });
      return json({ success: true, message: "Logged (Telegram not configured)" });
    }

    const res = await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text }),
    });
    const body = await res.json();
    if (!res.ok || !body.ok) {
      console.error("[Waitlist notify] Telegram request failed:", res.status, body);
      // Release the claim so it can be retried.
      await admin.from("notifications").update({ group_notified_at: null }).eq("id", notificationId);
      return json({ error: "Failed to send Telegram message" }, 502);
    }
    return json({ success: true });
  } catch (err) {
    return json({ error: (err as Error).message }, 500);
  }
});
