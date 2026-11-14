/*
# The waiting list is first come, first served

Before: when a place opened (a cancellation or an expired hold), anyone who
opened the session page could book it straight away. The automatic promotion
only ran every 5 minutes, so the person at the front of the queue could be
beaten to the place, and people who booked that way stayed on the list as
"Waiting".

Now:
1. A player can only book a place if there are more free places than people
   queued ahead of them. Someone at the front of the queue can take the first
   free place; someone not on the list can only book places the queue doesn't
   need. Admins and the promotion function are not affected.
2. The moment a booking is cancelled, the next people in the queue are booked
   in (not up to 5 minutes later).
3. Whoever ends up with a booking is taken off the list, however they got it.
*/

-- People ahead of p_user_id in the queue (everyone waiting if they aren't queued).
CREATE OR REPLACE FUNCTION public.waitlist_ahead_count(p_session_id uuid, p_user_id uuid)
RETURNS integer
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM waiting_list wl
  WHERE wl.session_id = p_session_id
    AND wl.status = 'Waiting'
    AND wl.user_id <> p_user_id
    AND wl.queue_position < COALESCE(
      (SELECT me.queue_position FROM waiting_list me
       WHERE me.session_id = p_session_id AND me.user_id = p_user_id AND me.status = 'Waiting'
       ORDER BY me.queue_position LIMIT 1),
      2147483647);
$$;

-- Called from the booking trigger, which runs as the player (same as next_waitlist_position).
REVOKE ALL ON FUNCTION public.waitlist_ahead_count(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.waitlist_ahead_count(uuid, uuid) TO authenticated;

-- 1) Players can't jump the queue.
CREATE OR REPLACE FUNCTION public.enforce_waitlist_queue()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_capacity integer;
  v_ahead integer;
BEGIN
  IF current_user NOT IN ('anon', 'authenticated') OR is_admin() OR owns_session(NEW.session_id) THEN
    RETURN NEW;
  END IF;
  IF NEW.booking_status NOT IN ('Pending Payment', 'Confirmed') THEN
    RETURN NEW;
  END IF;

  -- Serialise bookings for a session so two people can't take the same place.
  -- (An advisory lock, because players can't lock the session row itself.)
  PERFORM pg_advisory_xact_lock(hashtextextended('vsb.booking.' || NEW.session_id::text, 0));
  SELECT maximum_capacity INTO v_capacity FROM sessions WHERE id = NEW.session_id;
  v_ahead := waitlist_ahead_count(NEW.session_id, NEW.user_id);

  IF v_capacity IS NOT NULL AND v_ahead > 0
     AND v_capacity - confirmed_booking_count(NEW.session_id) <= v_ahead THEN
    RAISE EXCEPTION 'Free places go to the waiting list first. You can join the waiting list.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_waitlist_queue() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS bookings_enforce_waitlist_queue ON public.bookings;
CREATE TRIGGER bookings_enforce_waitlist_queue
  BEFORE INSERT ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.enforce_waitlist_queue();

-- 2) Fill free places from the queue, in order. Returns how many were booked.
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
    AND se.status = 'Open'
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
    -- Already holding a place (booked another way)? Tidy the list, keep going.
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

-- The 5-minute job keeps working as a safety net, but uses the same function.
CREATE OR REPLACE FUNCTION public.process_booking_holds()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_released integer := 0;
  v_promoted integer := 0;
  r record;
  s record;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('vsb.process_booking_holds')) THEN
    RETURN jsonb_build_object('skipped', true);
  END IF;

  FOR r IN
    UPDATE bookings b
    SET booking_status = 'Cancelled by Admin',
        payment_status = 'Cancelled',
        cancelled_at = now(),
        cancellation_reason = 'Released automatically: payment not received within the hold time'
    WHERE b.booking_status = 'Pending Payment'
      AND b.payment_status <> 'Paid'
      AND b.receipt_path IS NULL
      AND b.reserved_until IS NOT NULL
      AND b.reserved_until < now()
      AND EXISTS (
        SELECT 1 FROM sessions se
        WHERE se.id = b.session_id
          AND ((se.session_date + se.start_time) AT TIME ZONE 'Asia/Kuala_Lumpur') > now()
      )
    RETURNING b.id, b.user_id, b.is_guest, b.session_id
  LOOP
    v_released := v_released + 1;
    IF NOT r.is_guest THEN
      INSERT INTO notifications (user_id, booking_id, notification_type, title, message, delivery_channel, delivery_status, sent_at)
      SELECT r.user_id, r.id, 'booking_released', 'Booking released',
             'Your place for "' || se.title || '" was released because payment wasn''t received in time. Book again if places are still open.',
             'in_app', 'Sent', now()
      FROM sessions se WHERE se.id = r.session_id;
    END IF;
  END LOOP;

  FOR s IN
    SELECT DISTINCT wl.session_id FROM waiting_list wl WHERE wl.status = 'Waiting'
  LOOP
    v_promoted := v_promoted + promote_waitlist(s.session_id);
  END LOOP;

  RETURN jsonb_build_object('released', v_released, 'promoted', v_promoted);
END;
$$;

REVOKE ALL ON FUNCTION public.process_booking_holds() FROM PUBLIC, anon, authenticated;

-- Promote as soon as a place is freed.
CREATE OR REPLACE FUNCTION public.promote_waitlist_on_cancel()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.booking_status IN ('Pending Payment', 'Confirmed')
     AND NEW.booking_status NOT IN ('Pending Payment', 'Confirmed') THEN
    PERFORM promote_waitlist(NEW.session_id);
  END IF;
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.promote_waitlist_on_cancel() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS bookings_promote_waitlist ON public.bookings;
CREATE TRIGGER bookings_promote_waitlist
  AFTER UPDATE OF booking_status ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.promote_waitlist_on_cancel();

-- 3) Anyone who ends up with a booking leaves the list.
CREATE OR REPLACE FUNCTION public.leave_waitlist_on_booking()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT NEW.is_guest AND NEW.booking_status IN ('Pending Payment', 'Confirmed') THEN
    UPDATE waiting_list SET status = 'Booked'
    WHERE session_id = NEW.session_id AND user_id = NEW.user_id AND status = 'Waiting';
  END IF;
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.leave_waitlist_on_booking() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS bookings_leave_waitlist ON public.bookings;
CREATE TRIGGER bookings_leave_waitlist
  AFTER INSERT ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.leave_waitlist_on_booking();
