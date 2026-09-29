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
      drivers: {
        Row: {
          created_at: string
          deleted_at: string | null
          first_name: string
          has_ac: boolean
          is_active: boolean
          is_demo: boolean
          is_online: boolean
          last_lat: number | null
          last_lng: number | null
          last_seen_at: string | null
          phone: string
          status: string
          updated_at: string
          user_id: string
          vehicle_model: string
          vehicle_plate: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          first_name: string
          has_ac?: boolean
          is_active?: boolean
          is_demo?: boolean
          is_online?: boolean
          last_lat?: number | null
          last_lng?: number | null
          last_seen_at?: string | null
          phone: string
          status?: string
          updated_at?: string
          user_id: string
          vehicle_model: string
          vehicle_plate: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          first_name?: string
          has_ac?: boolean
          is_active?: boolean
          is_demo?: boolean
          is_online?: boolean
          last_lat?: number | null
          last_lng?: number | null
          last_seen_at?: string | null
          phone?: string
          status?: string
          updated_at?: string
          user_id?: string
          vehicle_model?: string
          vehicle_plate?: string
        }
        Relationships: []
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
          access_token: string
          chauffeur_id: string | null
          client_name: string
          client_phone: string
          created_at: string
          dropoff_location: string
          id: string
          is_demo: boolean
          payment_method: string
          pickup_lat: number | null
          pickup_lng: number | null
          pickup_location: string
          price_proposed: number
          resolved_at: string | null
          started_negotiation_at: string | null
          status: string
          updated_at: string
          wants_ac: boolean
        }
        Insert: {
          access_token: string
          chauffeur_id?: string | null
          client_name: string
          client_phone: string
          created_at?: string
          dropoff_location: string
          id?: string
          is_demo?: boolean
          payment_method: string
          pickup_lat?: number | null
          pickup_lng?: number | null
          pickup_location: string
          price_proposed: number
          resolved_at?: string | null
          started_negotiation_at?: string | null
          status?: string
          updated_at?: string
          wants_ac?: boolean
        }
        Update: {
          access_token?: string
          chauffeur_id?: string | null
          client_name?: string
          client_phone?: string
          created_at?: string
          dropoff_location?: string
          id?: string
          is_demo?: boolean
          payment_method?: string
          pickup_lat?: number | null
          pickup_lng?: number | null
          pickup_location?: string
          price_proposed?: number
          resolved_at?: string | null
          started_negotiation_at?: string | null
          status?: string
          updated_at?: string
          wants_ac?: boolean
        }
        Relationships: []
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
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      activate_driver_day: { Args: never; Returns: string }
      approve_driver: {
        Args: { _approve: boolean; _user_id: string }
        Returns: undefined
      }
      cancel_ride_public: {
        Args: { _ride_id: string; _token: string }
        Returns: boolean
      }
      check_and_purge_negotiation_timeouts: { Args: never; Returns: number }
      claim_first_superadmin: { Args: never; Returns: boolean }
      close_ride: {
        Args: { _ride_id: string; _success: boolean }
        Returns: string
      }
      compute_eta: {
        Args: { _lat1: number; _lat2: number; _lng1: number; _lng2: number }
        Returns: Record<string, unknown>
      }
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
      get_localized_pool_for_driver: {
        Args: { _lat: number; _lng: number; _radius_km?: number }
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
      get_public_activity: {
        Args: never
        Returns: {
          active_passengers: number
          drivers_online: number
          matches_today: number
        }[]
      }
      has_role: {
        Args: {
          _role: Database["public"]["Enums"]["app_role"]
          _user_id: string
        }
        Returns: boolean
      }
      is_active_driver: { Args: { _uid: string }; Returns: boolean }
      load_demo_data: { Args: never; Returns: undefined }
      log_ride_resolution: {
        Args: {
          _resolution: string
          _ride: Database["public"]["Tables"]["rides"]["Row"]
        }
        Returns: undefined
      }
      reset_demo_data: { Args: never; Returns: undefined }
      set_driver_active: {
        Args: { _active: boolean; _user_id: string }
        Returns: undefined
      }
      set_driver_availability: {
        Args: { _has_ac: boolean; _online: boolean }
        Returns: undefined
      }
      set_penalty_active: {
        Args: { _active: boolean; _id: string }
        Returns: undefined
      }
      setting_num: { Args: { _default: number; _key: string }; Returns: number }
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
