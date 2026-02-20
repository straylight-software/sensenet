// FFI for Header.purs

export const setThemeImpl = function(theme) {
  return function() {
    document.documentElement.setAttribute('data-theme', theme);
    localStorage.setItem('straylight-theme', theme);
  };
};

export const getStoredThemeImpl = function(defaultTheme) {
  return function() {
    return localStorage.getItem('straylight-theme') || defaultTheme;
  };
};
