/*
# Admins can undo a payment confirmation

confirm payment was one tap with no way back: a mis-tap left a booking
"Confirmed / Paid" with a cash payment on record that never happened.

admin_undo_confirmation(booking):
- the booking goes back to Pending Payment (payment "waiting for verification"),
  with a fresh hold (it is only released if it has no receipt and the hold runs out)
- the recorded payment is voided (status Cancelled), so totals stay right
- a note is added to the booking and the player is told it is back to pending
Admins only. Starter places (RM0) are not affected.
*/

CREATE OR REPLACE FUNCTION public.admin_undo_confirmation(p_booking_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  b bookings%ROWTYPE;
  v_title text;
BEGIN
  IF NOT is_admin() THEN
    RAISE EXCEPTION 'Only admins can do this' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO b FROM bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found'; END IF;
  IF b.booking_status <> 'Confirmed' OR b.payment_status <> 'Paid' THEN
    RAISE EXCEPTION 'Only a confirmed, paid booking can be undone';
  END IF;
  IF b.total_amount <= 0 THEN
    RAISE EXCEPTION 'Free (starter) places have no payment to undo';
  END IF;

  UPDATE payments SET payment_status = 'Cancelled'
  WHERE booking_id = p_booking_id AND payment_status = 'Paid';

  UPDATE bookings
  SET booking_status = 'Pending Payment',
      payment_status = 'Manual Payment Pending Verification',
      reserved_until = booking_hold_deadline(b.session_id),
      admin_notes = trim(both E'\n' from coalesce(b.admin_notes || E'\n', '') || 'Payment confirmation undone by an admin on ' || to_char(now() AT TIME ZONE 'Asia/Kuala_Lumpur', 'DD Mon HH24:MI'))
  WHERE id = p_booking_id;

  IF NOT b.is_guest THEN
    SELECT title INTO v_title FROM sessions WHERE id = b.session_id;
    INSERT INTO notifications (user_id, booking_id, notification_type, title, message, delivery_channel, delivery_status, sent_at)
    VALUES (b.user_id, b.id, 'payment_needed', 'Payment still needed',
            'Your place for "' || v_title || '" is back to pending: we haven''t received your payment yet. Pay and upload your receipt to keep your place.',
            'in_app', 'Sent', now());
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_undo_confirmation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_undo_confirmation(uuid) TO authenticated;
