━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                                    // nar.io
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Nix binary cache that doesn't suck. Landing site + admin portal for the Cachix killer.

## Stack

- **PureScript** + **Halogen** — UI
- **Tailwind CSS** — styling
- **Clerk** — authentication (GitHub/Google SSO)
- **Stripe** — billing
- **agenix** — secrets management
- **Nix** — reproducible builds
- **Vercel** — deployment


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                              // development
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

```bash
# Enter dev shell (secrets auto-exported via agenix-shell)
nix develop

# Or with direnv
direnv allow

# Install JS dependencies
npm install

# Start dev server
npm run dev
# http://localhost:3000
```


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                                  // secrets
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Secrets are managed with agenix. Encrypted `.age` files are committed to git.
Your SSH key decrypts them at dev time.

### First Time Setup

1. Add your SSH public key to `secrets/keys.nix`:

```nix
users = {
  "yourname" = [
    "ssh-ed25519 AAAA..."  # your key
  ];
};
```

2. Rekey all secrets (if they exist):

```bash
cd secrets
agenix -r secrets.nix
```

### Creating Secrets

```bash
# Enter secrets shell
cd secrets
nix develop ..#secrets

# Create a new secret
agenix -e secrets/clerk-publishable-key.age
# Opens $EDITOR, paste your key, save

# Create all required secrets
agenix -e secrets/clerk-secret-key.age
agenix -e secrets/stripe-publishable-key.age
agenix -e secrets/stripe-secret-key.age
# ... etc
```

### How It Works

When you enter the dev shell, agenix-shell automatically:

1. Decrypts all `.age` files in `secrets/secrets/`
2. Exports them as environment variables
3. Variable names are derived from filenames:
   - `clerk-publishable-key.age` → `$CLERK_PUBLISHABLE_KEY`
   - `stripe-secret-key.age` → `$STRIPE_SECRET_KEY`

### Required Secrets

| Secret | Description |
|--------|-------------|
| `clerk-publishable-key` | Clerk frontend key |
| `clerk-secret-key` | Clerk backend key |
| `clerk-webhook-secret` | Clerk webhook signing |
| `stripe-publishable-key` | Stripe frontend key |
| `stripe-secret-key` | Stripe backend key |
| `stripe-webhook-secret` | Stripe webhook signing |
| `stripe-price-pro` | Stripe price ID for Pro plan |
| `stripe-price-team` | Stripe price ID for Team plan |
| `database-url` | Database connection string |
| `nativelink-endpoint` | NativeLink CAS endpoint |
| `nativelink-auth-token` | NativeLink auth token |


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                                    // build
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

```bash
# Build the complete site
nix build

# Output
ls result/
# index.html  main.js  styles.css  favicon.svg

# Preview locally
nix run
# http://localhost:8000
```


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                                  // deploy
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### Vercel

```bash
# Install Vercel CLI
npm i -g vercel

# Deploy
vercel --prod
```

Or connect to GitHub and Vercel will auto-deploy on push.

### Environment Variables

Set these in Vercel dashboard (or inject from secrets):

```
VITE_CLERK_PUBLISHABLE_KEY=pk_live_xxx
```

Backend secrets go in Vercel Functions environment, not frontend.


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                                // structure
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

```
nar-io/
├── flake.nix              # Nix build + agenix-shell
├── vercel.json            # Vercel deployment
├── CONVENTIONS.md         # Code style guide
│
├── secrets/
│   ├── keys.nix           # SSH public keys for encryption
│   ├── secrets.nix        # Secret definitions
│   ├── .envrc             # direnv for secrets shell
│   └── secrets/           # Encrypted .age files
│       ├── clerk-publishable-key.age
│       ├── clerk-secret-key.age
│       └── ...
│
├── public/
│   ├── index.html         # SEO, OG tags
│   └── favicon.svg
│
└── src/
    ├── Main.purs          # App entry, routing, auth
    ├── styles.css         # Tailwind source
    └── Nar/
        ├── Auth.purs/js   # Clerk FFI
        ├── Billing.purs/js # Stripe FFI
        ├── Router.purs    # Routes
        ├── UI.purs        # Components
        ├── Layout/
        │   ├── Header.purs
        │   └── Footer.purs
        └── Pages/
            ├── Home.purs
            ├── Pricing.purs
            ├── Docs.purs
            ├── Dashboard.purs  # protected
            └── Settings.purs   # protected
```


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                                  // routes
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

| Route | Auth | Description |
|-------|------|-------------|
| `/` | — | Landing page |
| `/pricing` | — | Pricing tiers |
| `/docs` | — | Documentation |
| `/login` | — | Clerk sign-in |
| `/signup` | — | Clerk sign-up |
| `/dashboard` | required | Cache management |
| `/settings` | required | Account, billing, team |


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                                  // license
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

MIT
