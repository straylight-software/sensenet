// FFI for Footer.purs

export const setIntervalImpl = function(ms) {
  return function(callback) {
    return function() {
      return setInterval(callback, ms);
    };
  };
};

export const clearIntervalImpl = function(id) {
  return function() {
    clearInterval(id);
  };
};
