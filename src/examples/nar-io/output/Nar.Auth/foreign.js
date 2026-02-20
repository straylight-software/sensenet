// Clerk Authentication FFI
// Requires @clerk/clerk-js

import { Clerk } from "@clerk/clerk-js";

let clerkInstance = null;

export const initClerkImpl = (publishableKey) => async (onError, onSuccess) => {
  try {
    clerkInstance = new Clerk(publishableKey);
    await clerkInstance.load();
    onSuccess();
  } catch (e) {
    console.error("Clerk init failed:", e);
    // Don't fail the app, just mark as not loaded
    onSuccess();
  }
  return (cancelError, onCancelerError, onCancelerSuccess) => {
    onCancelerSuccess();
  };
};

export const getAuthStateImpl = () => {
  if (!clerkInstance) {
    return { user: null, session: null, isLoaded: false };
  }
  return {
    user: clerkInstance.user ? {
      id: clerkInstance.user.id,
      email: clerkInstance.user.primaryEmailAddress?.emailAddress || "",
      firstName: clerkInstance.user.firstName,
      lastName: clerkInstance.user.lastName,
      imageUrl: clerkInstance.user.imageUrl,
      username: clerkInstance.user.username,
      publicMetadata: {
        plan: clerkInstance.user.publicMetadata?.plan || null,
        stripeCustomerId: clerkInstance.user.publicMetadata?.stripeCustomerId || null,
      },
    } : null,
    session: clerkInstance.session ? {
      id: clerkInstance.session.id,
      userId: clerkInstance.session.user.id,
      expireAt: clerkInstance.session.expireAt.getTime(),
    } : null,
    isLoaded: clerkInstance.loaded,
  };
};

export const signInImpl = () => {
  if (clerkInstance) {
    clerkInstance.openSignIn();
  }
};

export const signUpImpl = () => {
  if (clerkInstance) {
    clerkInstance.openSignUp();
  }
};

export const signOutImpl = (onError, onSuccess) => {
  if (!clerkInstance) {
    onSuccess();
    return;
  }
  clerkInstance.signOut()
    .then(() => onSuccess())
    .catch((e) => onError(e));
  return (cancelError, onCancelerError, onCancelerSuccess) => {
    onCancelerSuccess();
  };
};

export const openUserProfileImpl = () => {
  if (clerkInstance) {
    clerkInstance.openUserProfile();
  }
};

export const onAuthStateChangeImpl = (callback) => () => {
  if (!clerkInstance) {
    return () => {};
  }
  const unsubscribe = clerkInstance.addListener((emission) => {
    callback();
  });
  return () => {
    unsubscribe();
  };
};

// Helper to get session token for API calls
export const getSessionToken = async () => {
  if (!clerkInstance?.session) {
    return null;
  }
  return await clerkInstance.session.getToken();
};
