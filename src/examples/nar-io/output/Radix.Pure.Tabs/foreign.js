// Tabs.js - getElementById FFI

export const getElementByIdImpl = id => doc => () => doc.getElementById(id);
