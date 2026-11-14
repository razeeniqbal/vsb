/*
# Tell the club group when someone moves up from the waiting list

Players only get in-app notifications, so the club's Telegram group is where
people actually find out. When the waiting list books someone in, the database
asks the waitlist-group-notify edge function (via pg_net) to post one message
to the group: who moved up, how much to pay and the 12-hour deadline.

Respects the existing "notify the group" setting (club_settings.whatsapp_group_notify).
A failure here never affects the booking itself.

Two vault entries (set once, outside the repo, per project):
  waitlist_notify_url      the project's URL, e.g. https://<ref>.supabase.co
  waitlist_notify_anon_key the project's public anon key (lets the call through the gateway)
*/

ALTER TABLE public.notifications ADD COLUMN IF NOT EXISTS group_notified_at timestamptz;

CREATE OR REPLACE FUNCTION public.announce_waitlist_promotion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url text;
  v_key text;
BEGIN
  IF NEW.notification_type <> 'waitlist_promoted' THEN
    RETURN NULL;
  END IF;

  BEGIN
    SELECT decrypted_secret INTO v_url FROM vault.decrypted_secrets WHERE name = 'waitlist_notify_url';
    SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'waitlist_notify_anon_key';
    IF v_url IS NULL OR v_key IS NULL THEN
      RETURN NULL;
    END IF;

    PERFORM net.http_post(
      url := v_url || '/functions/v1/waitlist-group-notify',
      body := jsonb_build_object('notificationId', NEW.id),
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key)
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'announce_waitlist_promotion failed: %', SQLERRM;
  END;
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.announce_waitlist_promotion() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS notifications_announce_waitlist ON public.notifications;
CREATE TRIGGER notifications_announce_waitlist
  AFTER INSERT ON public.notifications
  FOR EACH ROW EXECUTE FUNCTION public.announce_waitlist_promotion();
