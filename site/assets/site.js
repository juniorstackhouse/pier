// The little things the page does: the install command's Copy button, the cards that tilt under the pointer and the
// parts that rise into view as you scroll. The page reads the same without it.
(function () {
  var root = document.documentElement;
  var still = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
  root.classList.add('js');

  document.querySelectorAll('[data-copy]').forEach(function (b) {
    b.addEventListener('click', function () {
      if (!navigator.clipboard) return;
      navigator.clipboard.writeText(b.getAttribute('data-copy')).then(function () {
        b.classList.add('copied');
        setTimeout(function () { b.classList.remove('copied'); }, 1600);
      }, function () {});
    });
  });

  // the hero's 3D scene (hero.js): if it is not up in a few seconds, the picture of the mascot stands in
  var stage = document.querySelector('[data-hero-stage]');
  if (stage) setTimeout(function () { if (!stage.classList.contains('is-ready')) stage.classList.add('is-fallback'); }, 5000);

  var risers = document.querySelectorAll('.rise');
  if (still || !('IntersectionObserver' in window)) {
    risers.forEach(function (e) { e.classList.add('in'); });
  } else {
    var seen = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) { en.target.classList.add('in'); seen.unobserve(en.target); }
      });
    }, { rootMargin: '0px 0px -8% 0px' });
    risers.forEach(function (e) { seen.observe(e); });
  }

  if (!still && matchMedia('(hover: hover)').matches) {
    document.querySelectorAll('.card').forEach(function (c) {
      c.addEventListener('pointermove', function (e) {
        var r = c.getBoundingClientRect();
        var x = (e.clientX - r.left) / r.width - 0.5, y = (e.clientY - r.top) / r.height - 0.5;
        c.style.transform = 'perspective(900px) rotateX(' + (-y * 6).toFixed(2) + 'deg) rotateY(' + (x * 8).toFixed(2) + 'deg) translateY(-4px)';
      });
      c.addEventListener('pointerleave', function () { c.style.transform = ''; });
    });
  }
})();
