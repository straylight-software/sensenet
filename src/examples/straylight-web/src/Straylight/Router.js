// FFI for Router.purs

export const getPathname = () => window.location.pathname;

export const pushState = (path) => () => {
  window.history.pushState({}, "", path);
  // Dispatch popstate so listeners pick it up
  window.dispatchEvent(new PopStateEvent("popstate"));
};

export const onPopState = (callback) => () => {
  window.addEventListener("popstate", () => {
    callback(window.location.pathname)();
  });
};
