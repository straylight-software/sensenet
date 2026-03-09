// FFI for Header.purs

export const setThemeImpl = (theme) => () => {
  document.documentElement.setAttribute("data-theme", theme);
  localStorage.setItem("straylight-theme", theme);
};

export const getStoredThemeImpl = (defaultTheme) => () =>
  localStorage.getItem("straylight-theme") || defaultTheme;
