// FFI for Footer.purs

export const setIntervalImpl = (ms) => (callback) => () => setInterval(callback, ms);

export const clearIntervalImpl = (id) => () => {
  clearInterval(id);
};
