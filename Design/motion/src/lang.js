// The film's language: English (the default) or Brazilian Portuguese (`?lang=pt`). Every word on screen is written
// `say(english, portuguese)` where it is drawn; the interface's words are the app's own (App/Resources/Localizable.xcstrings).
export const LANG = new URLSearchParams(location.search).get('lang') === 'pt' ? 'pt' : 'en';
export const say = (en, pt) => (LANG === 'pt' ? pt : en);
document.documentElement.lang = say('en', 'pt-BR');
