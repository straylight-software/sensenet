# Secrets configuration for nar.io
# Run `agenix -e secrets/<name>.age` to create/edit secrets
let
  inherit (import ./keys.nix) users hosts;

  # Combine all user keys
  allUsers = builtins.concatLists (builtins.attrValues users);

  # Combine all host keys
  allHosts = builtins.concatLists (builtins.attrValues hosts);

  # All keys that can decrypt secrets
  allKeys = allUsers ++ allHosts;
in
{
  # ============================================================
  # CLERK - Authentication
  # ============================================================

  # Clerk publishable key (safe for frontend, but keep in secrets for consistency)
  "secrets/clerk-publishable-key.age".publicKeys = allKeys;

  # Clerk secret key (backend only, never expose to frontend)
  "secrets/clerk-secret-key.age".publicKeys = allKeys;

  # Clerk webhook signing secret
  "secrets/clerk-webhook-secret.age".publicKeys = allKeys;

  # ============================================================
  # STRIPE - Payments
  # ============================================================

  # Stripe publishable key (safe for frontend)
  "secrets/stripe-publishable-key.age".publicKeys = allKeys;

  # Stripe secret key (backend only)
  "secrets/stripe-secret-key.age".publicKeys = allKeys;

  # Stripe webhook signing secret
  "secrets/stripe-webhook-secret.age".publicKeys = allKeys;

  # Stripe price IDs
  "secrets/stripe-price-pro.age".publicKeys = allKeys;
  "secrets/stripe-price-team.age".publicKeys = allKeys;

  # ============================================================
  # DATABASE
  # ============================================================

  # Database connection URL (if using external DB)
  "secrets/database-url.age".publicKeys = allKeys;

  # ============================================================
  # NATIVELINK CAS - Cache Backend
  # ============================================================

  # NativeLink API endpoint
  "secrets/nativelink-endpoint.age".publicKeys = allKeys;

  # NativeLink auth token
  "secrets/nativelink-auth-token.age".publicKeys = allKeys;

  # ============================================================
  # ANALYTICS
  # ============================================================

  # Plausible domain (optional)
  "secrets/plausible-domain.age".publicKeys = allKeys;
}
