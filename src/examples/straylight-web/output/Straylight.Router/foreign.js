// FFI for Router.purs

export const getPathname = function() {
  return window.location.pathname;
};

export const pushState = function(path) {
  return function() {
    window.history.pushState({}, '', path);
    // Dispatch popstate so listeners pick it up
    window.dispatchEvent(new PopStateEvent('popstate'));
  };
};

export const onPopState = function(callback) {
  return function() {
    window.addEventListener('popstate', function() {
      callback(window.location.pathname)();
    });
  };
};
