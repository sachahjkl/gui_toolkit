// The screenshots: a carousel, then a viewer. No dependency.
//
// The carousel. The page's .gallery is a grid of figures, each a link to its picture: without this script that grid is
// what shows. With it, the gallery is a track that scrolls sideways, one figure at a time (CSS scroll snap: a finger's
// swipe and a touchpad's are the browser's own), with Previous and Next buttons, a count read out as it changes, and a
// row of thumbnails, each a button to its figure. Left and Right (Home, End) go through them when the keyboard is in the
// carousel. A thumbnail takes the narrowest picture of its figure's srcset (site.build_images made them).
//
// The viewer. Every capture is a plain link to its image, so without this script (or in a browser with no <dialog>) a
// click still opens the picture. With it, a click opens the picture large over the page: Left and Right go through the
// captures, Home and End to the first and the last, Esc or a click on the picture closes, and the keyboard comes back to
// the link of the capture last shown (the carousel shows its figure).
(function () {
  'use strict';

  function make(tag, cls, text) {
    var el = document.createElement(tag);
    if (cls) el.className = cls;
    if (text) el.textContent = text;
    return el;
  }
  function button(cls, text, action) {
    var b = make('button', cls, text);
    b.type = 'button';
    b.addEventListener('click', action);
    return b;
  }
  var still = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  ////////////////////////////////
  // The carousel

  // The narrowest picture of an <img>'s srcset ("a-360.webp 360w, a.webp 1280w"), else its src.
  function narrowest(img) {
    var best = img.getAttribute('src'), least = Infinity;
    (img.getAttribute('srcset') || '').split(',').forEach(function (part) {
      var bits = part.trim().split(/\s+/), w = parseInt(bits[1], 10);
      if (bits[0] && w > 0 && w < least) { least = w; best = bits[0]; }
    });
    return best;
  }

  // A figure's title: its caption's <strong>, else its picture's alt text.
  function title_of(figure, i) {
    var strong = figure.querySelector('figcaption strong'), img = figure.querySelector('img');
    if (strong) return strong.textContent;
    return img && img.alt ? img.alt : 'Screenshot ' + (i + 1);
  }

  var carousel = null;   // what the viewer tells of the picture it shows: show(i) of the carousel's figures
  var track = document.querySelector('section.gallery');
  var slides = track ? Array.prototype.slice.call(track.querySelectorAll(':scope > figure.shot')) : [];
  if (slides.length > 1 && 'scrollTo' in track) {
    var box = make('div', 'carousel');
    box.setAttribute('role', 'region');
    box.setAttribute('aria-roledescription', 'carousel');
    box.setAttribute('aria-label', 'Screenshots');
    track.parentNode.insertBefore(box, track);
    track.classList.add('carousel-track');
    track.tabIndex = 0;
    track.setAttribute('aria-label', 'Screenshots, one at a time: Left and Right go through them');
    slides.forEach(function (f, i) {
      f.setAttribute('role', 'group');
      f.setAttribute('aria-roledescription', 'slide');
      f.setAttribute('aria-label', (i + 1) + ' of ' + slides.length + ': ' + title_of(f, i));
    });

    var current = 0;
    var prev = button('carousel-arrow prev', '', function () { go(current - 1); });
    var next = button('carousel-arrow next', '', function () { go(current + 1); });
    prev.setAttribute('aria-label', 'Previous screenshot');
    next.setAttribute('aria-label', 'Next screenshot');
    var stage = make('div', 'carousel-stage');
    stage.appendChild(prev);
    stage.appendChild(track);
    stage.appendChild(next);
    var count = make('p', 'carousel-count');
    count.setAttribute('aria-live', 'polite');
    var thumbs = make('div', 'carousel-thumbs');
    thumbs.setAttribute('aria-label', 'Every screenshot');
    var marks = slides.map(function (f, i) {
      var t = button('carousel-thumb', '', function () { go(i); });
      var name = title_of(f, i);
      t.setAttribute('aria-label', 'Screenshot ' + (i + 1) + ': ' + name);
      t.title = name;
      var img = f.querySelector('img');
      if (img) {
        var small = document.createElement('img');
        small.src = narrowest(img);
        small.alt = '';
        small.loading = 'lazy';
        small.decoding = 'async';
        t.appendChild(small);
      }
      thumbs.appendChild(t);
      return t;
    });
    box.appendChild(stage);
    box.appendChild(count);
    box.appendChild(thumbs);

    // (the figure shown is the one the track's scroll stands on: a swipe moves it as a button does)
    function shown(i) {
      if (i === current && count.textContent) return;
      current = i;
      count.textContent = (i + 1) + ' / ' + slides.length + ' · ' + title_of(slides[i], i);
      marks.forEach(function (m, k) {
        if (k === i) m.setAttribute('aria-current', 'true'); else m.removeAttribute('aria-current');
      });
      prev.disabled = i === 0;
      next.disabled = i === slides.length - 1;
      var m = marks[i];   // (its thumbnail in view, the row scrolled, not the page)
      var left = m.offsetLeft - (thumbs.clientWidth - m.offsetWidth) / 2;
      thumbs.scrollTo({left: Math.max(0, left), behavior: still ? 'auto' : 'smooth'});
    }
    function go(i, at_once) {
      i = Math.max(0, Math.min(slides.length - 1, i));
      track.scrollTo({left: slides[i].offsetLeft, behavior: still || at_once ? 'auto' : 'smooth'});
      shown(i);
    }
    var pending = 0;
    track.addEventListener('scroll', function () {
      if (pending) return;
      pending = requestAnimationFrame(function () {
        pending = 0;
        shown(Math.round(track.scrollLeft / Math.max(1, track.clientWidth)));
      });
    }, {passive: true});
    box.addEventListener('keydown', function (e) {
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      switch (e.key) {
        case 'ArrowLeft': go(current - 1); break;
        case 'ArrowRight': go(current + 1); break;
        case 'Home': go(0); break;
        case 'End': go(slides.length - 1); break;
        default: return;
      }
      e.preventDefault();
    });
    shown(0);
    carousel = {
      show: function (link) {
        for (var i = 0; i < slides.length; i++) { if (slides[i].contains(link)) { go(i, true); return; } }
      },
    };
  }

  ////////////////////////////////
  // The viewer

  var links = Array.prototype.slice.call(document.querySelectorAll('.shot a.frame'));
  var dialog = document.createElement('dialog');
  if (!links.length || typeof dialog.showModal !== 'function') return;

  var at = 0;
  var stage_box = make('div', 'lightbox-stage');
  var picture = document.createElement('img');
  var caption = make('p', 'lightbox-caption');
  var counter = make('span', 'lightbox-count');
  var full = make('a', 'btn', 'Full size');
  var closer = button('btn accent', 'Close', close);

  counter.setAttribute('aria-live', 'polite');
  full.title = 'The image alone, at its own size';
  stage_box.appendChild(picture);
  stage_box.addEventListener('click', close);

  var actions = make('div', 'lightbox-actions');
  actions.appendChild(counter);
  actions.appendChild(button('btn', 'Previous', function () { show(at - 1); }));
  actions.appendChild(button('btn', 'Next', function () { show(at + 1); }));
  actions.appendChild(full);
  actions.appendChild(closer);

  var bar = make('div', 'lightbox-bar');
  bar.appendChild(caption);
  bar.appendChild(actions);

  dialog.className = 'lightbox';
  dialog.setAttribute('aria-label', 'Screenshot');
  dialog.appendChild(stage_box);
  dialog.appendChild(bar);
  document.body.appendChild(dialog);

  function show(i) {
    at = (i + links.length) % links.length;
    var link = links[at];
    var thumb = link.querySelector('img');
    var text = link.parentNode.querySelector('figcaption');
    picture.removeAttribute('src');   // never the last picture under this caption while the next one loads
    picture.alt = thumb ? thumb.alt : '';
    picture.src = link.getAttribute('href');
    full.href = link.getAttribute('href');
    counter.textContent = (at + 1) + ' / ' + links.length;
    while (caption.firstChild) caption.removeChild(caption.firstChild);
    if (text) {
      for (var n = text.firstChild; n; n = n.nextSibling) caption.appendChild(n.cloneNode(true));
    }
  }

  function open(i) {
    show(i);
    document.documentElement.classList.add('lightbox-open');
    dialog.showModal();
    closer.focus();
  }

  function close() {
    if (dialog.open) dialog.close();
    done();
  }

  // once, whichever way the viewer closed (the close button, the picture, or the browser's own Esc)
  function done() {
    if (!document.documentElement.classList.contains('lightbox-open')) return;
    document.documentElement.classList.remove('lightbox-open');
    picture.removeAttribute('src');
    if (carousel) carousel.show(links[at]);
    links[at].focus({preventScroll: true});
  }
  dialog.addEventListener('close', done);

  dialog.addEventListener('keydown', function (e) {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    switch (e.key) {
      case 'Escape': close(); break;
      case 'ArrowLeft': show(at - 1); break;
      case 'ArrowRight': show(at + 1); break;
      case 'Home': show(0); break;
      case 'End': show(links.length - 1); break;
      default: return;
    }
    e.preventDefault();
    e.stopPropagation();   // (the carousel under it keeps its place)
  });

  links.forEach(function (link, i) {
    link.addEventListener('click', function (e) {
      if (e.button !== 0 || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) return;   // a new tab, as asked
      e.preventDefault();
      open(i);
    });
  });
})();
