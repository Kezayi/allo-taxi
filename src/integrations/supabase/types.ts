export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.18"
  }
  public: {
    Tables: {
      associate_share_rules: {
        Row: {
          associate_id: string
          created_at: string
          created_by: string | null
          effective_from: string
          effective_to: string | null
          id: string
          share_percent: number
          source: string
          updated_at: string
        }
        Insert: {
          associate_id: string
          created_at?: string
          created_by?: string | null
          effective_from: string
          effective_to?: string | null
          id?: string
          share_percent: number
          source: string
          updated_at?: string
        }
        Update: {
          associate_id?: string
          created_at?: string
          created_by?: string | null
          effective_from?: string
          effective_to?: string | null
          id?: string
          share_percent?: number
          source?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "associate_share_rules_associate_id_fkey"
            columns: ["associate_id"]
            isOneToOne: false
            referencedRelation: "associates"
            referencedColumns: ["id"]
          },
        ]
      }
      associates: {
        Row: {
          created_at: string
          deleted_at: string | null
          display_name: string
          id: string
          is_active: boolean
          partner_key: string
          phone: string | null
          updated_at: string
          user_id: string | null
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          display_name: string
          id?: string
          is_active?: boolean
          partner_key: string
          phone?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          display_name?: string
          id?: string
          is_active?: boolean
          partner_key?: string
          phone?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "associates_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
        ]
      }
      associates_settings: {
        Row: {
          created_at: string
          deleted_at: string | null
          display_name: string
          id: string
          is_active: boolean
          partner_key: string
          phone: string
          share_percent: number
          updated_at: string
          user_id: string | null
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          display_name: string
          id?: string
          is_active?: boolean
          partner_key: string
          phone: string
          share_percent: number
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          display_name?: string
          id?: string
          is_active?: boolean
          partner_key?: string
          phone?: string
          share_percent?: number
          updated_at?: string
          user_id?: string | null
        }
        Relationships: []
      }
      audit_events: {
        Row: {
          actor_id: string | null
          actor_type: string
          correlation_id: string | null
          entity_id: string | null
          entity_type: string
          event_type: string
          id: number
          metadata: Json
          occurred_at: string
          reason: string | null
          source: string
        }
        Insert: {
          actor_id?: string | null
          actor_type: string
          correlation_id?: string | null
          entity_id?: string | null
          entity_type: string
          event_type: string
          id?: never
          metadata?: Json
          occurred_at?: string
          reason?: string | null
          source: string
        }
        Update: {
          actor_id?: string | null
          actor_type?: string
          correlation_id?: string | null
          entity_id?: string | null
          entity_type?: string
          event_type?: string
          id?: never
          metadata?: Json
          occurred_at?: string
          reason?: string | null
          source?: string
        }
        Relationships: []
      }
      client_identities: {
        Row: {
          created_at: string
          first_seen_at: string
          id: string
          last_display_name: string | null
          last_seen_at: string
          phone: string
          phone_verified_at: string | null
          trust_level: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          first_seen_at: string
          id?: string
          last_display_name?: string | null
          last_seen_at: string
          phone: string
          phone_verified_at?: string | null
          trust_level?: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          first_seen_at?: string
          id?: string
          last_display_name?: string | null
          last_seen_at?: string
          phone?: string
          phone_verified_at?: string | null
          trust_level?: string
          updated_at?: string
        }
        Relationships: []
      }
      client_restrictions: {
        Row: {
          client_identity_id: string
          created_at: string
          created_by: string
          ends_at: string | null
          id: string
          lift_reason: string | null
          lifted_at: string | null
          lifted_by: string | null
          reason: string
          restriction_type: string
          starts_at: string
        }
        Insert: {
          client_identity_id: string
          created_at?: string
          created_by: string
          ends_at?: string | null
          id?: string
          lift_reason?: string | null
          lifted_at?: string | null
          lifted_by?: string | null
          reason: string
          restriction_type: string
          starts_at?: string
        }
        Update: {
          client_identity_id?: string
          created_at?: string
          created_by?: string
          ends_at?: string | null
          id?: string
          lift_reason?: string | null
          lifted_at?: string | null
          lifted_by?: string | null
          reason?: string
          restriction_type?: string
          starts_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "client_restrictions_client_identity_id_fkey"
            columns: ["client_identity_id"]
            isOneToOne: false
            referencedRelation: "client_identities"
            referencedColumns: ["id"]
          },
        ]
      }
      driver_day_passes: {
        Row: {
          activated_at: string | null
          created_at: string
          driver_id: string
          expires_at: string
          grant_reason: string | null
          granted_by: string | null
          id: string
          legacy_subscription_id: string | null
          mode: string
          origin: string
          price_fcfa: number
          service_day: string
          status: string
          updated_at: string
        }
        Insert: {
          activated_at?: string | null
          created_at?: string
          driver_id: string
          expires_at: string
          grant_reason?: string | null
          granted_by?: string | null
          id?: string
          legacy_subscription_id?: string | null
          mode: string
          origin: string
          price_fcfa?: number
          service_day: string
          status: string
          updated_at?: string
        }
        Update: {
          activated_at?: string | null
          created_at?: string
          driver_id?: string
          expires_at?: string
          grant_reason?: string | null
          granted_by?: string | null
          id?: string
          legacy_subscription_id?: string | null
          mode?: string
          origin?: string
          price_fcfa?: number
          service_day?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "driver_day_passes_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: false
            referencedRelation: "drivers"
            referencedColumns: ["user_id"]
          },
        ]
      }
      driver_document_ai_runs: {
        Row: {
          attempts: number
          document_id: string
          error_code: string | null
          finished_at: string | null
          started_at: string
          status: string
        }
        Insert: {
          attempts?: number
          document_id: string
          error_code?: string | null
          finished_at?: string | null
          started_at?: string
          status: string
        }
        Update: {
          attempts?: number
          document_id?: string
          error_code?: string | null
          finished_at?: string | null
          started_at?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "driver_document_ai_runs_document_id_fkey"
            columns: ["document_id"]
            isOneToOne: true
            referencedRelation: "driver_documents"
            referencedColumns: ["id"]
          },
        ]
      }
      driver_document_checks: {
        Row: {
          ai_model: string | null
          anomalies: Json
          confidence: number | null
          created_at: string
          decision: string | null
          document_id: string
          extracted_data: Json
          id: string
          method: string
          result: string
          reviewer_id: string | null
        }
        Insert: {
          ai_model?: string | null
          anomalies?: Json
          confidence?: number | null
          created_at?: string
          decision?: string | null
          document_id: string
          extracted_data?: Json
          id?: string
          method: string
          result: string
          reviewer_id?: string | null
        }
        Update: {
          ai_model?: string | null
          anomalies?: Json
          confidence?: number | null
          created_at?: string
          decision?: string | null
          document_id?: string
          extracted_data?: Json
          id?: string
          method?: string
          result?: string
          reviewer_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "driver_document_checks_document_id_fkey"
            columns: ["document_id"]
            isOneToOne: false
            referencedRelation: "driver_documents"
            referencedColumns: ["id"]
          },
        ]
      }
      driver_documents: {
        Row: {
          created_at: string
          doc_type: string
          driver_id: string
          expires_on: string | null
          id: string
          is_current: boolean
          issued_on: string | null
          mime_type: string | null
          sha256: string | null
          size_bytes: number | null
          status: string
          storage_bucket: string
          storage_path: string
          supersedes_id: string | null
          updated_at: string
          uploaded_by: string
          vehicle_id: string | null
          version: number
        }
        Insert: {
          created_at?: string
          doc_type: string
          driver_id: string
          expires_on?: string | null
          id?: string
          is_current?: boolean
          issued_on?: string | null
          mime_type?: string | null
          sha256?: string | null
          size_bytes?: number | null
          status?: string
          storage_bucket?: string
          storage_path: string
          supersedes_id?: string | null
          updated_at?: string
          uploaded_by: string
          vehicle_id?: string | null
          version?: number
        }
        Update: {
          created_at?: string
          doc_type?: string
          driver_id?: string
          expires_on?: string | null
          id?: string
          is_current?: boolean
          issued_on?: string | null
          mime_type?: string | null
          sha256?: string | null
          size_bytes?: number | null
          status?: string
          storage_bucket?: string
          storage_path?: string
          supersedes_id?: string | null
          updated_at?: string
          uploaded_by?: string
          vehicle_id?: string | null
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "driver_documents_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: false
            referencedRelation: "drivers"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "driver_documents_supersedes_id_fkey"
            columns: ["supersedes_id"]
            isOneToOne: false
            referencedRelation: "driver_documents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "driver_documents_vehicle_id_fkey"
            columns: ["vehicle_id"]
            isOneToOne: false
            referencedRelation: "vehicles"
            referencedColumns: ["id"]
          },
        ]
      }
      driver_penalties: {
        Row: {
          created_at: string
          deleted_at: string | null
          driver_id: string
          id: string
          is_active: boolean
          is_demo: boolean
          reason: string
          ride_id: string | null
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          driver_id: string
          id?: string
          is_active?: boolean
          is_demo?: boolean
          reason: string
          ride_id?: string | null
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          driver_id?: string
          id?: string
          is_active?: boolean
          is_demo?: boolean
          reason?: string
          ride_id?: string | null
        }
        Relationships: []
      }
      driver_presence: {
        Row: {
          accepting_new_shared: boolean
          accuracy_m: number | null
          auto_closed_at: string | null
          availability: string
          created_at: string
          driver_id: string
          heading_deg: number | null
          last_heartbeat_at: string | null
          lat: number | null
          lng: number | null
          position_at: string | null
          updated_at: string
          went_online_at: string | null
        }
        Insert: {
          accepting_new_shared?: boolean
          accuracy_m?: number | null
          auto_closed_at?: string | null
          availability?: string
          created_at?: string
          driver_id: string
          heading_deg?: number | null
          last_heartbeat_at?: string | null
          lat?: number | null
          lng?: number | null
          position_at?: string | null
          updated_at?: string
          went_online_at?: string | null
        }
        Update: {
          accepting_new_shared?: boolean
          accuracy_m?: number | null
          auto_closed_at?: string | null
          availability?: string
          created_at?: string
          driver_id?: string
          heading_deg?: number | null
          last_heartbeat_at?: string | null
          lat?: number | null
          lng?: number | null
          position_at?: string | null
          updated_at?: string
          went_online_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "driver_presence_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: true
            referencedRelation: "drivers"
            referencedColumns: ["user_id"]
          },
        ]
      }
      driver_restrictions: {
        Row: {
          created_at: string
          created_by: string
          driver_id: string
          ends_at: string | null
          id: string
          lift_reason: string | null
          lifted_at: string | null
          lifted_by: string | null
          penalty_id: string | null
          reason: string
          restriction_type: string
          source: string
          starts_at: string
        }
        Insert: {
          created_at?: string
          created_by: string
          driver_id: string
          ends_at?: string | null
          id?: string
          lift_reason?: string | null
          lifted_at?: string | null
          lifted_by?: string | null
          penalty_id?: string | null
          reason: string
          restriction_type: string
          source?: string
          starts_at?: string
        }
        Update: {
          created_at?: string
          created_by?: string
          driver_id?: string
          ends_at?: string | null
          id?: string
          lift_reason?: string | null
          lifted_at?: string | null
          lifted_by?: string | null
          penalty_id?: string | null
          reason?: string
          restriction_type?: string
          source?: string
          starts_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "driver_restrictions_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: false
            referencedRelation: "drivers"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "driver_restrictions_penalty_id_fkey"
            columns: ["penalty_id"]
            isOneToOne: false
            referencedRelation: "driver_penalties"
            referencedColumns: ["id"]
          },
        ]
      }
      drivers: {
        Row: {
          active_vehicle_id: string | null
          created_at: string
          deleted_at: string | null
          first_name: string
          has_ac: boolean
          is_active: boolean
          is_demo: boolean
          is_online: boolean
          last_lat: number | null
          last_lng: number | null
          last_name: string | null
          last_seen_at: string | null
          onboarding_status: string
          phone: string
          status: string
          updated_at: string
          user_id: string
          vehicle_model: string
          vehicle_plate: string
          whatsapp_phone: string | null
        }
        Insert: {
          active_vehicle_id?: string | null
          created_at?: string
          deleted_at?: string | null
          first_name: string
          has_ac?: boolean
          is_active?: boolean
          is_demo?: boolean
          is_online?: boolean
          last_lat?: number | null
          last_lng?: number | null
          last_name?: string | null
          last_seen_at?: string | null
          onboarding_status?: string
          phone: string
          status?: string
          updated_at?: string
          user_id: string
          vehicle_model: string
          vehicle_plate: string
          whatsapp_phone?: string | null
        }
        Update: {
          active_vehicle_id?: string | null
          created_at?: string
          deleted_at?: string | null
          first_name?: string
          has_ac?: boolean
          is_active?: boolean
          is_demo?: boolean
          is_online?: boolean
          last_lat?: number | null
          last_lng?: number | null
          last_name?: string | null
          last_seen_at?: string | null
          onboarding_status?: string
          phone?: string
          status?: string
          updated_at?: string
          user_id?: string
          vehicle_model?: string
          vehicle_plate?: string
          whatsapp_phone?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "drivers_active_vehicle_id_fkey"
            columns: ["active_vehicle_id"]
            isOneToOne: false
            referencedRelation: "vehicles"
            referencedColumns: ["id"]
          },
        ]
      }
      notification_outbox: {
        Row: {
          attempt_count: number
          available_at: string
          channel: string
          created_at: string
          dedupe_key: string
          id: number
          last_attempt_at: string | null
          last_error: string | null
          locked_at: string | null
          locked_by: string | null
          notification_type: string
          payload: Json
          recipient_id: string
          recipient_type: string
          ride_event_id: number | null
          ride_id: string | null
          sent_at: string | null
          status: string
          updated_at: string
        }
        Insert: {
          attempt_count?: number
          available_at?: string
          channel: string
          created_at?: string
          dedupe_key: string
          id?: never
          last_attempt_at?: string | null
          last_error?: string | null
          locked_at?: string | null
          locked_by?: string | null
          notification_type: string
          payload?: Json
          recipient_id: string
          recipient_type: string
          ride_event_id?: number | null
          ride_id?: string | null
          sent_at?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          attempt_count?: number
          available_at?: string
          channel?: string
          created_at?: string
          dedupe_key?: string
          id?: never
          last_attempt_at?: string | null
          last_error?: string | null
          locked_at?: string | null
          locked_by?: string | null
          notification_type?: string
          payload?: Json
          recipient_id?: string
          recipient_type?: string
          ride_event_id?: number | null
          ride_id?: string | null
          sent_at?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "notification_outbox_ride_event_id_fkey"
            columns: ["ride_event_id"]
            isOneToOne: false
            referencedRelation: "ride_events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notification_outbox_ride_id_fkey"
            columns: ["ride_id"]
            isOneToOne: false
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
        ]
      }
      onboarding_control: {
        Row: {
          ai_auto_approve_enabled: boolean
          ai_auto_approve_min_confidence: number
          enforced_at: string | null
          enforced_by: string | null
          enforcement_mode: string
          id: boolean
          updated_at: string
        }
        Insert: {
          ai_auto_approve_enabled?: boolean
          ai_auto_approve_min_confidence?: number
          enforced_at?: string | null
          enforced_by?: string | null
          enforcement_mode?: string
          id?: boolean
          updated_at?: string
        }
        Update: {
          ai_auto_approve_enabled?: boolean
          ai_auto_approve_min_confidence?: number
          enforced_at?: string | null
          enforced_by?: string | null
          enforcement_mode?: string
          id?: boolean
          updated_at?: string
        }
        Relationships: []
      }
      payment_transactions: {
        Row: {
          amount_base_fcfa: number
          amount_total_fcfa: number
          created_at: string
          currency: string
          driver_day_pass_id: string | null
          error_code: string | null
          error_message: string | null
          fees_fcfa: number
          id: string
          internal_reference: string
          operation_type: string
          operator: string | null
          payer_driver_id: string | null
          payer_msisdn: string | null
          provider: string
          provider_completed_at: string | null
          provider_metadata: Json
          provider_net_amount_fcfa: number | null
          refund_of_id: string | null
          resolved_at: string | null
          status: string
          updated_at: string
          xfin_reference: string | null
        }
        Insert: {
          amount_base_fcfa: number
          amount_total_fcfa: number
          created_at?: string
          currency?: string
          driver_day_pass_id?: string | null
          error_code?: string | null
          error_message?: string | null
          fees_fcfa?: number
          id?: string
          internal_reference: string
          operation_type: string
          operator?: string | null
          payer_driver_id?: string | null
          payer_msisdn?: string | null
          provider: string
          provider_completed_at?: string | null
          provider_metadata?: Json
          provider_net_amount_fcfa?: number | null
          refund_of_id?: string | null
          resolved_at?: string | null
          status?: string
          updated_at?: string
          xfin_reference?: string | null
        }
        Update: {
          amount_base_fcfa?: number
          amount_total_fcfa?: number
          created_at?: string
          currency?: string
          driver_day_pass_id?: string | null
          error_code?: string | null
          error_message?: string | null
          fees_fcfa?: number
          id?: string
          internal_reference?: string
          operation_type?: string
          operator?: string | null
          payer_driver_id?: string | null
          payer_msisdn?: string | null
          provider?: string
          provider_completed_at?: string | null
          provider_metadata?: Json
          provider_net_amount_fcfa?: number | null
          refund_of_id?: string | null
          resolved_at?: string | null
          status?: string
          updated_at?: string
          xfin_reference?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payment_transactions_driver_day_pass_id_fkey"
            columns: ["driver_day_pass_id"]
            isOneToOne: false
            referencedRelation: "driver_day_passes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_transactions_payer_driver_id_fkey"
            columns: ["payer_driver_id"]
            isOneToOne: false
            referencedRelation: "drivers"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "payment_transactions_refund_of_id_fkey"
            columns: ["refund_of_id"]
            isOneToOne: false
            referencedRelation: "payment_transactions"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles: {
        Row: {
          avatar_url: string | null
          created_at: string
          deleted_at: string | null
          first_name: string | null
          id: string
          is_active: boolean
          phone: string | null
          preferences: Json
          updated_at: string
          user_id: string
        }
        Insert: {
          avatar_url?: string | null
          created_at?: string
          deleted_at?: string | null
          first_name?: string | null
          id?: string
          is_active?: boolean
          phone?: string | null
          preferences?: Json
          updated_at?: string
          user_id: string
        }
        Update: {
          avatar_url?: string | null
          created_at?: string
          deleted_at?: string | null
          first_name?: string | null
          id?: string
          is_active?: boolean
          phone?: string | null
          preferences?: Json
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      ride_assignments: {
        Row: {
          confirmed_at: string | null
          created_at: string
          driver_id: string
          end_reason: string | null
          ended_at: string | null
          id: string
          ride_id: string
          source: string
          started_at: string
          status: string
          vehicle_id: string | null
        }
        Insert: {
          confirmed_at?: string | null
          created_at?: string
          driver_id: string
          end_reason?: string | null
          ended_at?: string | null
          id?: string
          ride_id: string
          source: string
          started_at: string
          status: string
          vehicle_id?: string | null
        }
        Update: {
          confirmed_at?: string | null
          created_at?: string
          driver_id?: string
          end_reason?: string | null
          ended_at?: string | null
          id?: string
          ride_id?: string
          source?: string
          started_at?: string
          status?: string
          vehicle_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "ride_assignments_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: false
            referencedRelation: "drivers"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "ride_assignments_ride_id_fkey"
            columns: ["ride_id"]
            isOneToOne: false
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ride_assignments_vehicle_id_fkey"
            columns: ["vehicle_id"]
            isOneToOne: false
            referencedRelation: "vehicles"
            referencedColumns: ["id"]
          },
        ]
      }
      ride_events: {
        Row: {
          actor_id: string | null
          actor_type: string
          assignment_id: string | null
          event_type: string
          from_status_v2: string | null
          id: number
          occurred_at: string
          payload: Json
          ride_id: string
          source: string
          to_status_v2: string | null
        }
        Insert: {
          actor_id?: string | null
          actor_type: string
          assignment_id?: string | null
          event_type: string
          from_status_v2?: string | null
          id?: never
          occurred_at?: string
          payload?: Json
          ride_id: string
          source: string
          to_status_v2?: string | null
        }
        Update: {
          actor_id?: string | null
          actor_type?: string
          assignment_id?: string | null
          event_type?: string
          from_status_v2?: string | null
          id?: never
          occurred_at?: string
          payload?: Json
          ride_id?: string
          source?: string
          to_status_v2?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "ride_events_assignment_id_fkey"
            columns: ["assignment_id"]
            isOneToOne: false
            referencedRelation: "ride_assignments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ride_events_ride_id_fkey"
            columns: ["ride_id"]
            isOneToOne: false
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
        ]
      }
      ride_logs: {
        Row: {
          chauffeur_id: string | null
          chauffeur_name: string | null
          chauffeur_phone: string | null
          client_name: string
          client_phone: string
          dropoff_location: string
          id: string
          is_demo: boolean
          matched_at: string | null
          payment_method: string | null
          pickup_location: string
          proposed_price: number
          published_at: string | null
          resolution_status: string
          resolved_at: string
          ride_id: string
          vehicle_plate: string | null
          wants_ac: boolean | null
        }
        Insert: {
          chauffeur_id?: string | null
          chauffeur_name?: string | null
          chauffeur_phone?: string | null
          client_name: string
          client_phone: string
          dropoff_location: string
          id?: string
          is_demo?: boolean
          matched_at?: string | null
          payment_method?: string | null
          pickup_location: string
          proposed_price: number
          published_at?: string | null
          resolution_status: string
          resolved_at?: string
          ride_id: string
          vehicle_plate?: string | null
          wants_ac?: boolean | null
        }
        Update: {
          chauffeur_id?: string | null
          chauffeur_name?: string | null
          chauffeur_phone?: string | null
          client_name?: string
          client_phone?: string
          dropoff_location?: string
          id?: string
          is_demo?: boolean
          matched_at?: string | null
          payment_method?: string | null
          pickup_location?: string
          proposed_price?: number
          published_at?: string | null
          resolution_status?: string
          resolved_at?: string
          ride_id?: string
          vehicle_plate?: string | null
          wants_ac?: boolean | null
        }
        Relationships: []
      }
      ride_public_status: {
        Row: {
          chauffeur_first_name: string | null
          chauffeur_phone: string | null
          driver_distance_km: number | null
          eta_minutes: number | null
          ride_id: string
          status: string
          updated_at: string
          vehicle_model: string | null
          vehicle_plate: string | null
        }
        Insert: {
          chauffeur_first_name?: string | null
          chauffeur_phone?: string | null
          driver_distance_km?: number | null
          eta_minutes?: number | null
          ride_id: string
          status: string
          updated_at?: string
          vehicle_model?: string | null
          vehicle_plate?: string | null
        }
        Update: {
          chauffeur_first_name?: string | null
          chauffeur_phone?: string | null
          driver_distance_km?: number | null
          eta_minutes?: number | null
          ride_id?: string
          status?: string
          updated_at?: string
          vehicle_model?: string | null
          vehicle_plate?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "ride_public_status_ride_id_fkey"
            columns: ["ride_id"]
            isOneToOne: true
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
        ]
      }
      rides: {
        Row: {
          access_token: string | null
          access_token_hash: string
          allow_sharing: boolean
          anchor_ride_id: string | null
          boarded_at: string | null
          chauffeur_id: string | null
          client_identity_id: string | null
          client_name: string
          client_phone: string
          created_at: string
          dropoff_lat: number | null
          dropoff_lng: number | null
          dropoff_location: string
          dropoff_note: string | null
          id: string
          is_demo: boolean
          passenger_count: number | null
          payment_method: string
          pickup_landmark: string | null
          pickup_lat: number | null
          pickup_lng: number | null
          pickup_location: string
          price_final: number | null
          price_final_confirmed_at: string | null
          price_proposed: number
          resolved_at: string | null
          started_negotiation_at: string | null
          status: string
          status_v2: string | null
          status_v2_changed_at: string | null
          updated_at: string
          vehicle_id: string | null
          wants_ac: boolean
          workflow_version: string
        }
        Insert: {
          access_token?: string | null
          access_token_hash: string
          allow_sharing?: boolean
          anchor_ride_id?: string | null
          boarded_at?: string | null
          chauffeur_id?: string | null
          client_identity_id?: string | null
          client_name: string
          client_phone: string
          created_at?: string
          dropoff_lat?: number | null
          dropoff_lng?: number | null
          dropoff_location: string
          dropoff_note?: string | null
          id?: string
          is_demo?: boolean
          passenger_count?: number | null
          payment_method: string
          pickup_landmark?: string | null
          pickup_lat?: number | null
          pickup_lng?: number | null
          pickup_location: string
          price_final?: number | null
          price_final_confirmed_at?: string | null
          price_proposed: number
          resolved_at?: string | null
          started_negotiation_at?: string | null
          status?: string
          status_v2?: string | null
          status_v2_changed_at?: string | null
          updated_at?: string
          vehicle_id?: string | null
          wants_ac?: boolean
          workflow_version?: string
        }
        Update: {
          access_token?: string | null
          access_token_hash?: string
          allow_sharing?: boolean
          anchor_ride_id?: string | null
          boarded_at?: string | null
          chauffeur_id?: string | null
          client_identity_id?: string | null
          client_name?: string
          client_phone?: string
          created_at?: string
          dropoff_lat?: number | null
          dropoff_lng?: number | null
          dropoff_location?: string
          dropoff_note?: string | null
          id?: string
          is_demo?: boolean
          passenger_count?: number | null
          payment_method?: string
          pickup_landmark?: string | null
          pickup_lat?: number | null
          pickup_lng?: number | null
          pickup_location?: string
          price_final?: number | null
          price_final_confirmed_at?: string | null
          price_proposed?: number
          resolved_at?: string | null
          started_negotiation_at?: string | null
          status?: string
          status_v2?: string | null
          status_v2_changed_at?: string | null
          updated_at?: string
          vehicle_id?: string | null
          wants_ac?: boolean
          workflow_version?: string
        }
        Relationships: [
          {
            foreignKeyName: "rides_client_identity_id_fkey"
            columns: ["client_identity_id"]
            isOneToOne: false
            referencedRelation: "client_identities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rides_vehicle_id_fkey"
            columns: ["vehicle_id"]
            isOneToOne: false
            referencedRelation: "vehicles"
            referencedColumns: ["id"]
          },
        ]
      }
      subscriptions: {
        Row: {
          amount: number
          created_at: string
          day: string
          driver_id: string
          id: string
          is_demo: boolean
          provider: string
          status: string
        }
        Insert: {
          amount?: number
          created_at?: string
          day?: string
          driver_id: string
          id?: string
          is_demo?: boolean
          provider?: string
          status?: string
        }
        Update: {
          amount?: number
          created_at?: string
          day?: string
          driver_id?: string
          id?: string
          is_demo?: boolean
          provider?: string
          status?: string
        }
        Relationships: []
      }
      system_settings: {
        Row: {
          key: string
          updated_at: string
          value: Json
        }
        Insert: {
          key: string
          updated_at?: string
          value: Json
        }
        Update: {
          key?: string
          updated_at?: string
          value?: Json
        }
        Relationships: []
      }
      user_roles: {
        Row: {
          created_at: string
          deleted_at: string | null
          id: string
          is_active: boolean
          role: Database["public"]["Enums"]["app_role"]
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          role: Database["public"]["Enums"]["app_role"]
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          role?: Database["public"]["Enums"]["app_role"]
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      vehicles: {
        Row: {
          capacity_source: string | null
          color: string | null
          created_at: string
          deleted_at: string | null
          driver_id: string
          has_ac: boolean
          id: string
          is_active: boolean
          is_demo: boolean
          make: string | null
          model: string
          passenger_capacity: number | null
          plate: string
          plate_normalized: string | null
          registered_seats: number | null
          updated_at: string
          validated_at: string | null
          validated_by: string | null
          validation_status: string
        }
        Insert: {
          capacity_source?: string | null
          color?: string | null
          created_at?: string
          deleted_at?: string | null
          driver_id: string
          has_ac?: boolean
          id?: string
          is_active?: boolean
          is_demo?: boolean
          make?: string | null
          model: string
          passenger_capacity?: number | null
          plate: string
          plate_normalized?: string | null
          registered_seats?: number | null
          updated_at?: string
          validated_at?: string | null
          validated_by?: string | null
          validation_status?: string
        }
        Update: {
          capacity_source?: string | null
          color?: string | null
          created_at?: string
          deleted_at?: string | null
          driver_id?: string
          has_ac?: boolean
          id?: string
          is_active?: boolean
          is_demo?: boolean
          make?: string | null
          model?: string
          passenger_capacity?: number | null
          plate?: string
          plate_normalized?: string | null
          registered_seats?: number | null
          updated_at?: string
          validated_at?: string | null
          validated_by?: string | null
          validation_status?: string
        }
        Relationships: [
          {
            foreignKeyName: "vehicles_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: false
            referencedRelation: "drivers"
            referencedColumns: ["user_id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      activate_driver_day: { Args: never; Returns: string }
      activate_my_driver_day_v1: {
        Args: { _payment_msisdn?: string }
        Returns: Json
      }
      admin_get_driver_dossier: { Args: { _driver_id: string }; Returns: Json }
      admin_list_driver_ai_checks: {
        Args: { _driver_id: string }
        Returns: Json
      }
      admin_list_driver_dossiers: {
        Args: never
        Returns: {
          approved_docs: number
          correction_docs: number
          driver_id: string
          driver_status: string
          expired_docs: number
          first_name: string
          global_state: string
          is_demo: boolean
          last_name: string
          onboarding_status: string
          passenger_capacity: number
          pending_docs: number
          registered_seats: number
          vehicle_id: string
          vehicle_label: string
          vehicle_plate: string
          vehicle_validation: string
        }[]
      }
      advance_ride_v1: {
        Args: { _action: string; _ride_id: string }
        Returns: Json
      }
      ai_complete_document_analysis: {
        Args: { _document_id: string; _model: string; _result: Json }
        Returns: Json
      }
      ai_fail_document_analysis: {
        Args: { _document_id: string; _error_code: string }
        Returns: undefined
      }
      apply_xfin_transaction_update: {
        Args: {
          _amount: number
          _completed_at: string
          _fees: number
          _net_amount: number
          _source: string
          _status: string
          _transaction_type: string
          _xfin_reference: string
        }
        Returns: Json
      }
      approve_driver: {
        Args: { _approve: boolean; _user_id: string }
        Returns: undefined
      }
      assert_driver_documents_gate: {
        Args: { _driver_id: string }
        Returns: undefined
      }
      bearing_deg: {
        Args: { _lat1: number; _lat2: number; _lng1: number; _lng2: number }
        Returns: number
      }
      cancel_ride_by_driver_v1: {
        Args: { _reason: string; _ride_id: string }
        Returns: Json
      }
      cancel_ride_public: {
        Args: { _ride_id: string; _token: string }
        Returns: boolean
      }
      cancel_ride_v1: {
        Args: { _ride_id: string; _token: string }
        Returns: Json
      }
      check_and_purge_negotiation_timeouts: { Args: never; Returns: number }
      claim_first_superadmin: { Args: never; Returns: boolean }
      close_ride: {
        Args: { _ride_id: string; _success: boolean }
        Returns: string
      }
      compute_driver_onboarding_state: {
        Args: { _driver_id: string }
        Returns: string
      }
      compute_driver_operational_eligibility: {
        Args: { _driver_id: string }
        Returns: Json
      }
      compute_eta: {
        Args: { _lat1: number; _lat2: number; _lng1: number; _lng2: number }
        Returns: Record<string, unknown>
      }
      confirm_ride_after_contact_v1: {
        Args: { _final_price: number; _ride_id: string; _token: string }
        Returns: Json
      }
      create_ride_public: {
        Args: {
          _allow_sharing: boolean
          _client_name: string
          _client_phone: string
          _dropoff_lat?: number
          _dropoff_lng?: number
          _dropoff_location: string
          _payment_method: string
          _pickup_lat?: number
          _pickup_lng?: number
          _pickup_location: string
          _price: number
          _wants_ac: boolean
        }
        Returns: {
          id: string
          token: string
        }[]
      }
      create_ride_public_v1: {
        Args: {
          _allow_sharing: boolean
          _client_name: string
          _client_phone: string
          _dropoff_location: string
          _dropoff_note: string
          _passenger_count: number
          _payment_method: string
          _pickup_landmark: string
          _pickup_lat: number
          _pickup_lng: number
          _pickup_location: string
          _price: number
          _wants_ac: boolean
        }
        Returns: {
          ride_id: string
          token: string
        }[]
      }
      doc_type_requires_expiry: {
        Args: { _doc_type: string }
        Returns: boolean
      }
      document_effective_status: {
        Args: { _expires_on: string; _status: string }
        Returns: string
      }
      driver_anchor_ride: {
        Args: { _uid: string }
        Returns: {
          access_token: string | null
          access_token_hash: string
          allow_sharing: boolean
          anchor_ride_id: string | null
          boarded_at: string | null
          chauffeur_id: string | null
          client_identity_id: string | null
          client_name: string
          client_phone: string
          created_at: string
          dropoff_lat: number | null
          dropoff_lng: number | null
          dropoff_location: string
          dropoff_note: string | null
          id: string
          is_demo: boolean
          passenger_count: number | null
          payment_method: string
          pickup_landmark: string | null
          pickup_lat: number | null
          pickup_lng: number | null
          pickup_location: string
          price_final: number | null
          price_final_confirmed_at: string | null
          price_proposed: number
          resolved_at: string | null
          started_negotiation_at: string | null
          status: string
          status_v2: string | null
          status_v2_changed_at: string | null
          updated_at: string
          vehicle_id: string | null
          wants_ac: boolean
          workflow_version: string
        }
        SetofOptions: {
          from: "*"
          to: "rides"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      driver_ticket_mode: { Args: never; Returns: string }
      drop_off_ride: { Args: { _ride_id: string }; Returns: string }
      enable_onboarding_enforcement: {
        Args: { _confirmation: string }
        Returns: Json
      }
      evaluate_driver_operational_eligibility: {
        Args: { _driver_id: string }
        Returns: Json
      }
      expire_ride_v1: { Args: { _ride_id: string }; Returns: Json }
      export_full_ride_logs: {
        Args: never
        Returns: {
          chauffeur_id: string | null
          chauffeur_name: string | null
          chauffeur_phone: string | null
          client_name: string
          client_phone: string
          dropoff_location: string
          id: string
          is_demo: boolean
          matched_at: string | null
          payment_method: string | null
          pickup_location: string
          proposed_price: number
          published_at: string | null
          resolution_status: string
          resolved_at: string
          ride_id: string
          vehicle_plate: string | null
          wants_ac: boolean | null
        }[]
        SetofOptions: {
          from: "*"
          to: "ride_logs"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      financial_dashboard_split: {
        Args: never
        Returns: {
          active_drivers_today: number
          display_name: string
          gross_revenue: number
          month: string
          partner_amount: number
          partner_key: string
          share_percent: number
          today_revenue: number
        }[]
      }
      financial_today_split: {
        Args: never
        Returns: {
          partner_key: string
          share_percent: number
          today_amount: number
        }[]
      }
      get_daily_price: { Args: never; Returns: number }
      get_document_storage_ref: {
        Args: { _document_id: string }
        Returns: Json
      }
      get_localized_pool_for_driver: {
        Args: { _lat: number; _lng: number; _radius_km: number }
        Returns: {
          created_at: string
          distance_km: number
          dropoff_location: string
          id: string
          payment_method: string
          pickup_location: string
          price_proposed: number
          wants_ac: boolean
        }[]
      }
      get_my_driver_day_access: { Args: never; Returns: Json }
      get_my_driver_onboarding: { Args: never; Returns: Json }
      get_onboarding_enforcement_status: { Args: never; Returns: Json }
      get_pool_v1: {
        Args: { _lat: number; _lng: number; _radius_km: number }
        Returns: {
          allow_sharing: boolean
          created_at: string
          distance_km: number
          dropoff_location: string
          dropoff_note: string
          passenger_count: number
          payment_method: string
          pickup_landmark: string
          pickup_location: string
          price_proposed: number
          ride_id: string
          wants_ac: boolean
        }[]
      }
      get_public_activity: {
        Args: never
        Returns: {
          active_passengers: number
          drivers_online: number
          matches_today: number
        }[]
      }
      get_ride_status: {
        Args: { _ride_id: string; _token: string }
        Returns: {
          chauffeur_first_name: string
          chauffeur_phone: string
          driver_distance_km: number
          eta_minutes: number
          status: string
          updated_at: string
          vehicle_model: string
          vehicle_plate: string
        }[]
      }
      get_ride_status_v1: {
        Args: { _ride_id: string; _token: string }
        Returns: Json
      }
      get_ticket_config: { Args: never; Returns: Json }
      has_role: {
        Args: {
          _role: Database["public"]["Enums"]["app_role"]
          _user_id: string
        }
        Returns: boolean
      }
      has_valid_driver_day_access: {
        Args: { _driver_id: string }
        Returns: boolean
      }
      is_active_driver: { Args: { _uid: string }; Returns: boolean }
      km_between: {
        Args: { _lat1: number; _lat2: number; _lng1: number; _lng2: number }
        Returns: number
      }
      libreville_day_end: { Args: { _day: string }; Returns: string }
      libreville_today: { Args: never; Returns: string }
      load_demo_data: { Args: never; Returns: undefined }
      log_audit_event: {
        Args: {
          _actor_id: string
          _actor_type: string
          _entity_id: string
          _entity_type: string
          _event_type: string
          _metadata?: Json
          _source: string
        }
        Returns: undefined
      }
      log_ride_resolution: {
        Args: {
          _resolution: string
          _ride: Database["public"]["Tables"]["rides"]["Row"]
        }
        Returns: undefined
      }
      mark_contact_failed_v1: {
        Args: { _ride_id: string; _token: string }
        Returns: Json
      }
      normalize_plate: { Args: { _plate: string }; Returns: string }
      onboarding_enforcement_mode: { Args: never; Returns: string }
      refresh_driver_onboarding_status: {
        Args: { _driver_id: string }
        Returns: string
      }
      register_my_document: {
        Args: {
          _doc_type: string
          _expires_on?: string
          _issued_on?: string
          _mime_type: string
          _sha256?: string
          _size_bytes: number
          _storage_path: string
          _vehicle_id?: string
        }
        Returns: Json
      }
      release_ride_v1: {
        Args: { _reason?: string; _ride_id: string }
        Returns: Json
      }
      request_document_ai_analysis: {
        Args: { _document_id: string }
        Returns: Json
      }
      reserve_ride_v1: { Args: { _ride_id: string }; Returns: Json }
      reset_demo_data: { Args: never; Returns: undefined }
      review_driver_document: {
        Args: { _decision: string; _document_id: string; _reason?: string }
        Returns: Json
      }
      review_driver_vehicle: {
        Args: { _decision: string; _reason?: string; _vehicle_id: string }
        Returns: Json
      }
      ride_same_direction: {
        Args: {
          a: Database["public"]["Tables"]["rides"]["Row"]
          c: Database["public"]["Tables"]["rides"]["Row"]
        }
        Returns: boolean
      }
      ride_v1_assert_driver_ready: {
        Args: { _uid: string }
        Returns: undefined
      }
      ride_v1_by_token: {
        Args: { _ride_id: string; _token: string }
        Returns: {
          access_token: string | null
          access_token_hash: string
          allow_sharing: boolean
          anchor_ride_id: string | null
          boarded_at: string | null
          chauffeur_id: string | null
          client_identity_id: string | null
          client_name: string
          client_phone: string
          created_at: string
          dropoff_lat: number | null
          dropoff_lng: number | null
          dropoff_location: string
          dropoff_note: string | null
          id: string
          is_demo: boolean
          passenger_count: number | null
          payment_method: string
          pickup_landmark: string | null
          pickup_lat: number | null
          pickup_lng: number | null
          pickup_location: string
          price_final: number | null
          price_final_confirmed_at: string | null
          price_proposed: number
          resolved_at: string | null
          started_negotiation_at: string | null
          status: string
          status_v2: string | null
          status_v2_changed_at: string | null
          updated_at: string
          vehicle_id: string | null
          wants_ac: boolean
          workflow_version: string
        }
        SetofOptions: {
          from: "*"
          to: "rides"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      ride_v1_event: {
        Args: {
          _actor: string
          _actor_type: string
          _assignment: string
          _from: string
          _payload?: Json
          _ride_id: string
          _to: string
          _type: string
        }
        Returns: undefined
      }
      ride_v1_legacy_status: { Args: { _s: string }; Returns: string }
      ride_v1_payment_code: { Args: { _legacy: string }; Returns: string }
      ride_v1_set_status: {
        Args: { _ride_id: string; _to: string }
        Returns: undefined
      }
      ride_v1_transition_allowed: {
        Args: { _from: string; _to: string }
        Returns: boolean
      }
      ride_v1_whatsapp_number: { Args: { _raw: string }; Returns: string }
      set_driver_active: {
        Args: { _active: boolean; _user_id: string }
        Returns: undefined
      }
      set_driver_availability: {
        Args: { _has_ac: boolean; _online: boolean }
        Returns: undefined
      }
      set_driver_ticket_mode: {
        Args: { _mode: string; _reason: string }
        Returns: Json
      }
      set_penalty_active: {
        Args: { _active: boolean; _id: string }
        Returns: undefined
      }
      set_shared_rides_enabled: { Args: { _on: boolean }; Returns: undefined }
      setting_num: { Args: { _default: number; _key: string }; Returns: number }
      shared_rides_enabled: { Args: never; Returns: boolean }
      superadmin_exists: { Args: never; Returns: boolean }
      take_ride: {
        Args: { _ride_id: string }
        Returns: {
          client_name: string
          client_phone: string
          dropoff_location: string
          id: string
          payment_method: string
          pickup_location: string
          price_proposed: number
          wants_ac: boolean
        }[]
      }
      update_driver_position: {
        Args: { _lat: number; _lng: number }
        Returns: number
      }
      update_system_settings: {
        Args: { _daily_price: number; _radius_km: number; _timeout_min: number }
        Returns: undefined
      }
      upsert_my_vehicle: {
        Args: {
          _color?: string
          _has_ac?: boolean
          _make?: string
          _model?: string
          _plate?: string
          _registered_seats?: number
          _set_active?: boolean
          _vehicle_id?: string
        }
        Returns: Json
      }
      url_encode: { Args: { _s: string }; Returns: string }
      xfin_integration_ready: { Args: never; Returns: boolean }
    }
    Enums: {
      app_role: "client" | "chauffeur" | "associe" | "super_admin"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      app_role: ["client", "chauffeur", "associe", "super_admin"],
    },
  },
} as const
