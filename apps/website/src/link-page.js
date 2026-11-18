// Shared by play.html (quiz link, #232) and join.html (game invite, #212); build.py inlines it.
// These pages open only without Trubbo installed: with the app, iOS opens the link in it.
// Puts the visitor's language first. With a valid token in `param`, the App Store button copies
// this page's link before it opens the store, so the friend still has it after the install.
function trubboLinkPage(param) {
  var lang = (navigator.language || "en").slice(0, 2);
  var mine = document.querySelector('section[lang="' + lang + '"]');
  if (mine) mine.parentNode.insertBefore(mine, mine.parentNode.firstChild);

  var token = new URLSearchParams(location.search).get(param) || "";
  var valid = /^[A-Za-z0-9_-]{8,64}$/.test(token);

  function legacyCopy(text) {
    var t = document.createElement("textarea");
    t.value = text; t.setAttribute("readonly", ""); t.style.position = "fixed"; t.style.opacity = "0";
    document.body.appendChild(t); t.select(); t.setSelectionRange(0, text.length);
    try { document.execCommand("copy"); } catch (e) {}
    t.remove();
  }
  function copy(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).catch(function () { legacyCopy(text); });
    }
    legacyCopy(text);
    return Promise.resolve();
  }
  document.querySelectorAll("a.get").forEach(function (a) {
    a.addEventListener("click", function (e) {
      if (!valid) return;
      e.preventDefault();
      copy(location.href).then(function () {
        setTimeout(function () { location.href = a.href; }, 300);
      });
    });
  });
  return { token: token, valid: valid };
}
