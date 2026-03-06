# secrets/secrets.nix
#
# Agenix secrets configuration for sensenet.
# Keys are encrypted with age and decrypted at runtime.
#
# Usage:
#   agenix -e secrets/gcp-nativelink.age  # Encrypt a new secret
#   agenix -r                              # Re-encrypt all secrets
#
let
  # b7r6's SSH key (converted to age format)
  b7r6 = "age1su5300500ydpytty5le9qqfu0wqcmahsx5x9kvd2y3cfqx8j5f6su9clfr";

  # All users who can decrypt secrets
  users = [ b7r6 ];
in
{
  # GCP service account key for NativeLink deployment
  # Contains: nativelink-deploy@straylight-486401.iam.gserviceaccount.com
  "gcp-nativelink.age".publicKeys = users;
}
