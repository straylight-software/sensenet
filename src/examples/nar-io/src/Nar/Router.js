// FFI for client-side routing

export const getPathname = () => window.location.pathname;

export const pushState = (path) => () => {
  window.history.pushState({}, "", path);
};

export const onPopState = (callback) => () => {
  window.addEventListener("popstate", () => {
    callback(window.location.pathname)();
  });
};
