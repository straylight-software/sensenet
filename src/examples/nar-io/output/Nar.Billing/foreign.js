// Stripe Billing FFI
// Calls backend API to create checkout/portal sessions

const API_BASE = "/api";

export const createCheckoutSessionImpl = (priceId) => (successUrl) => async (onError, onSuccess) => {
  try {
    // Get session token from Clerk
    const { getSessionToken } = await import("./Auth.js");
    const token = await getSessionToken();
    
    if (!token) {
      throw new Error("Not authenticated");
    }

    const response = await fetch(`${API_BASE}/billing/checkout`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${token}`,
      },
      body: JSON.stringify({
        priceId,
        successUrl,
        cancelUrl: window.location.href,
      }),
    });

    if (!response.ok) {
      throw new Error(`Checkout failed: ${response.statusText}`);
    }

    const { url } = await response.json();
    
    // Redirect to Stripe Checkout
    window.location.href = url;
    
    onSuccess(url);
  } catch (e) {
    onError(e);
  }
  return (cancelError, onCancelerError, onCancelerSuccess) => {
    onCancelerSuccess();
  };
};

export const openCustomerPortalImpl = (returnUrl) => async (onError, onSuccess) => {
  try {
    const { getSessionToken } = await import("./Auth.js");
    const token = await getSessionToken();
    
    if (!token) {
      throw new Error("Not authenticated");
    }

    const response = await fetch(`${API_BASE}/billing/portal`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${token}`,
      },
      body: JSON.stringify({ returnUrl }),
    });

    if (!response.ok) {
      throw new Error(`Portal failed: ${response.statusText}`);
    }

    const { url } = await response.json();
    
    // Redirect to Stripe Customer Portal
    window.location.href = url;
    
    onSuccess(url);
  } catch (e) {
    onError(e);
  }
  return (cancelError, onCancelerError, onCancelerSuccess) => {
    onCancelerSuccess();
  };
};
