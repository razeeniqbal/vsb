/*
# The waiting list also fills places on closed sessions

"Booking Closed" stops new bookings, but a place freed by a cancellation should
still go to the next person in the queue. Only games that have already started
(or start within 30 minutes) and cancelled sessions are left alone.
*/

CREATE OR REPLACE FUNCTION public.promote_waitlist(p_session_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s record;
  w record;
  v_free integer;
  v_booking_id uuid;
  v_promoted integer := 0;
BEGIN
  SELECT se.id, se.title, se.maximum_capacity, se.price INTO s
  FROM sessions se
  WHERE se.id = p_session_id
    AND se.status IN ('Open', 'Closed')
    AND ((se.session_date + se.start_time) AT TIME ZONE 'Asia/Kuala_Lumpur') > now() + interval '30 minutes'
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  v_free := s.maximum_capacity - confirmed_booking_count(s.id);

  FOR w IN
    SELECT wl.id, wl.user_id
    FROM waiting_list wl
    WHERE wl.session_id = s.id AND wl.status = 'Waiting'
    ORDER BY wl.queue_position NULLS LAST, wl.created_at
    FOR UPDATE SKIP LOCKED
  LOOP
    IF EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.session_id = s.id AND b.user_id = w.user_id AND NOT b.is_guest
        AND b.booking_status IN ('Pending Payment', 'Confirmed')
    ) THEN
      UPDATE waiting_list SET status = 'Booked' WHERE id = w.id;
      CONTINUE;
    END IF;

    EXIT WHEN v_free <= 0;

    INSERT INTO bookings (
      user_id, session_id, booking_status, payment_status,
      subtotal, processing_fee, discount_amount, total_amount, is_guest
    ) VALUES (
      w.user_id, s.id, 'Pending Payment', 'Manual Payment Pending Verification',
      s.price, 0, 0, s.price, false
    ) RETURNING id INTO v_booking_id;

    UPDATE waiting_list SET status = 'Booked' WHERE id = w.id;

    INSERT INTO notifications (user_id, booking_id, notification_type, title, message, delivery_channel, delivery_status, sent_at)
    VALUES (w.user_id, v_booking_id, 'waitlist_promoted', 'You''re in!',
            'A place opened up for "' || s.title || '" and it''s yours. Pay and upload your receipt before the hold runs out.',
            'in_app', 'Sent', now());

    v_free := v_free - 1;
    v_promoted := v_promoted + 1;
  END LOOP;

  RETURN v_promoted;
END;
$$;

REVOKE ALL ON FUNCTION public.promote_waitlist(uuid) FROM PUBLIC, anon, authenticated;

-- Tidy: anyone still "Waiting" for a game that has already started never got a place.
UPDATE waiting_list wl
SET status = 'Expired'
FROM sessions se
WHERE se.id = wl.session_id
  AND wl.status = 'Waiting'
  AND ((se.session_date + se.start_time) AT TIME ZONE 'Asia/Kuala_Lumpur') < now();
