// The film's frame: 1920 × 1080 (the default) or 1080 × 1920 (`?format=vertical`, for phones and social feeds). The
// story and its clock are the same; the scenes frame it for the shape.
const vertical = new URLSearchParams(location.search).get('format') === 'vertical';
export const FORMAT = vertical ? { name: 'vertical', w: 1080, h: 1920, vertical: true } : { name: 'wide', w: 1920, h: 1080, vertical: false };
document.documentElement.style.setProperty('--frame-w', `${FORMAT.w}px`);
document.documentElement.style.setProperty('--frame-h', `${FORMAT.h}px`);
document.documentElement.classList.toggle('vertical', vertical);
