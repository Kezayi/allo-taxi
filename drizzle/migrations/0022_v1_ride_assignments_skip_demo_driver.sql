CREATE OR REPLACE FUNCTION public.rides_sync_assignments()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.is_demo THEN RETURN NULL; END IF;

  IF TG_OP = 'UPDATE' AND OLD.chauffeur_id IS NOT NULL AND NEW.chauffeur_id IS DISTINCT FROM OLD.chauffeur_id THEN
    UPDATE public.ride_assignments SET status='released', ended_at=now(), end_reason='legacy_released'
     WHERE ride_id=NEW.id AND driver_id=OLD.chauffeur_id AND status='reserved';
  END IF;

  -- Chauffeurs démo jamais historisés (sinon reset_demo_data serait bloqué par la FK)
  IF NEW.chauffeur_id IS NOT NULL AND (TG_OP='INSERT' OR NEW.chauffeur_id IS DISTINCT FROM OLD.chauffeur_id)
     AND EXISTS (SELECT 1 FROM public.drivers d WHERE d.user_id = NEW.chauffeur_id AND NOT d.is_demo) THEN
    INSERT INTO public.ride_assignments (ride_id, driver_id, vehicle_id, status, source, started_at)
    VALUES (NEW.id, NEW.chauffeur_id, NEW.vehicle_id, 'reserved', 'legacy', now());
  END IF;

  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status AND NEW.chauffeur_id IS NOT NULL THEN
    IF OLD.status='negotiating' AND NEW.status='onboard' THEN
      UPDATE public.ride_assignments SET status='confirmed', confirmed_at=now()
       WHERE ride_id=NEW.id AND driver_id=NEW.chauffeur_id AND status='reserved';
    ELSIF OLD.status='onboard' AND NEW.status='completed' THEN
      UPDATE public.ride_assignments SET status='completed', ended_at=now()
       WHERE ride_id=NEW.id AND driver_id=NEW.chauffeur_id AND status='confirmed';
    ELSIF OLD.status='negotiating' AND NEW.status='canceled' THEN
      UPDATE public.ride_assignments SET status='canceled', ended_at=now(), end_reason='legacy_ride_canceled'
       WHERE ride_id=NEW.id AND driver_id=NEW.chauffeur_id AND status='reserved';
    END IF;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.rides_sync_assignments() FROM PUBLIC, anon, authenticated;