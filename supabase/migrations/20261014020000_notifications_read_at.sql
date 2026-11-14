/*
# Notifications can be marked as read

The app now shows each member's in-app notifications (a bell in the header),
so "You're in!" after a waiting-list promotion actually reaches them. read_at
marks when they were opened. Members already can update their own rows.
*/

ALTER TABLE public.notifications ADD COLUMN IF NOT EXISTS read_at timestamptz;
