# SSH public keys for encrypting secrets
# Add your SSH public key to decrypt secrets locally
{
  users = {
    # Add team members here
    # Format: "name" = [ "ssh-ed25519 AAAA..." ];
    "b7r6" = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ1ptqyz5C3YCcMgh3LUbXtjeS1rIZ5/6RHnH7D93Nqf"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINbn+XF6n9v9VKLFGLBVz+G1LyL6GlcgZbIwhP89PPsp"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILBEaqZY7H09brD/syW20HVDpYmKf44TOZ/Whzemwc/+"
    ];
  };

  # CI/CD and deployment hosts
  hosts = {
    # Add deployment targets here
    # "vercel-deploy" = [ "ssh-ed25519 AAAA..." ];
  };
}
