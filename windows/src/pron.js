// 가사 발음: 로마자(일본어 헵번식 · 중국어 병음) → 한글 발음
// Mac 판은 macOS 내장 변환을 썼지만 Windows 에는 없어서, 번역 서비스가 주는 로마자를 받아 여기서 한글로 바꿈
"use strict";

const Pron = (() => {
  // 초성 · 중성 · 종성 번호 (유니코드 한글 조합 순서)
  const CHO = { g: 0, kk: 1, n: 2, d: 3, r: 5, m: 6, b: 7, s: 9, ss: 10, "": 11, j: 12, jj: 13, ch: 14, k: 15, t: 16, p: 17, h: 18 };
  const V = { a: 0, ae: 1, ya: 2, eo: 4, e: 5, yeo: 6, ye: 7, o: 8, wa: 9, yo: 12, u: 13, wo: 14, wi: 16, yu: 17, eu: 18, i: 20 };
  const JONG = { "": 0, k: 1, n: 4, l: 8, m: 16, s: 19, ng: 21 };
  const syl = (c, v, f = "") => String.fromCharCode(0xac00 + (CHO[c] * 21 + V[v]) * 28 + JONG[f]);
  const addFinal = (out, f) => {
    const last = out.length ? out.charCodeAt(out.length - 1) : 0;
    if (last >= 0xac00 && last <= 0xd7a3 && (last - 0xac00) % 28 === 0) return out.slice(0, -1) + String.fromCharCode(last + JONG[f]);
    return out + (f === "n" ? "ㄴ" : f === "s" ? "ㅅ" : "");
  };
  const deaccent = (s) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").normalize("NFC");

  // MARK: 일본어 (헵번식 로마자 → 한글)

  const JV = { a: "a", i: "i", u: "u", e: "e", o: "o" };
  const JY = { a: "ya", u: "yu", o: "yo", e: "ye" };
  // 자음 → [초성, 모음 바꾸기]
  const JC = {
    k: "k", g: "g", s: "s", z: "j", t: "t", d: "d", n: "n", h: "h", b: "b", p: "p", m: "m", r: "r", f: "h", v: "b", j: "j", ch: "ch", sh: "s", ts: "ch",
  };
  function jaWord(w) {
    let out = "";
    let i = 0;
    const isV = (c) => "aiueo".includes(c);
    while (i < w.length) {
      const c = w[i], n1 = w[i + 1] || "";
      if (isV(c)) { out += syl("", JV[c]); i++; continue; }
      // ん: 모음이나 y 가 안 따라오는 n
      if (c === "n" && !isV(n1) && n1 !== "y") { out = addFinal(out, "n"); i += n1 === "n" || n1 === "'" ? 2 : 1; continue; }
      if (c === "m" && "bpm".includes(n1) && n1) { out = addFinal(out, "n"); i++; continue; }
      // っ: 같은 자음 두 번 (tch 포함)
      if ((c === n1 && c !== "n") || (c === "t" && w.startsWith("ch", i + 1))) { out = addFinal(out, "s"); i++; continue; }
      let cons = null, len = 0;
      for (const k of ["sh", "ch", "ts", "j", "k", "g", "s", "z", "t", "d", "n", "h", "f", "b", "p", "m", "r", "v", "y", "w"]) {
        if (w.startsWith(k, i)) { cons = k; len = k.length; break; }
      }
      if (!cons) { i++; continue; }
      let j = i + len;
      let glide = false;
      if (w[j] === "y" && cons !== "y") { glide = true; j++; }
      const v = w[j];
      if (!isV(v || "")) { i = j; continue; }
      i = j + 1;
      if (cons === "y") { out += syl("", JY[v] || "i"); continue; }
      if (cons === "w") { out += syl("", v === "a" ? "wa" : v === "o" ? "o" : v === "e" ? "e" : "wi"); continue; }
      let vow = JV[v];
      if (glide || ((cons === "sh" || cons === "j") && v !== "i")) vow = JY[v] || vow;
      if (cons === "ch" && v !== "i") vow = JV[v]; // 차 · 추 · 초
      if (cons === "j") vow = JV[v];                // 자 · 주 · 조
      if ((cons === "s" || cons === "ts" || cons === "z") && v === "u") vow = "eu"; // 스 · 츠 · 즈
      out += syl(JC[cons], vow);
    }
    return out;
  }

  // MARK: 중국어 (병음 → 한글)

  const ZI = { zh: "j", ch: "ch", sh: "s", b: "b", p: "p", m: "m", f: "p", d: "d", t: "t", n: "n", l: "r", g: "g", k: "k", h: "h", j: "j", q: "ch", x: "s", r: "r", z: "jj", c: "ch", s: "ss" };
  // 운모 → [[모음, 받침], ...] (둘째부터는 ㅇ 으로 시작하는 음절)
  const ZF = {
    a: [["a"]], o: [["o"]], e: [["eo"]], ai: [["a"], ["i"]], ei: [["e"], ["i"]], ao: [["a"], ["o"]], ou: [["eo"], ["u"]],
    an: [["a", "n"]], en: [["eo", "n"]], ang: [["a", "ng"]], eng: [["eo", "ng"]], ong: [["u", "ng"]], er: [["eo", "l"]],
    i: [["i"]], ia: [["ya"]], ie: [["ye"]], iao: [["ya"], ["o"]], iu: [["yu"]], ian: [["ye", "n"]], in: [["i", "n"]],
    iang: [["ya", "ng"]], ing: [["i", "ng"]], iong: [["yu", "ng"]], u: [["u"]], ua: [["wa"]], uo: [["wo"]], uai: [["wa"], ["i"]],
    ui: [["wi"]], uan: [["wa", "n"]], un: [["u", "n"]], uang: [["wa", "ng"]], ueng: [["wo", "ng"]], v: [["wi"]], ve: [["wi"], ["e"]],
    van: [["wi"], ["a", "n"]], vn: [["wi", "n"]],
  };
  const ZY = { yi: "i", ya: "ia", ye: "ie", yao: "iao", you: "iu", yan: "ian", yin: "in", yang: "iang", ying: "ing", yong: "iong", yu: "v", yue: "ve", yuan: "van", yun: "vn",
    wu: "u", wa: "ua", wo: "uo", wai: "uai", wei: "ui", wan: "uan", wen: "un", wang: "uang", weng: "ueng" };
  function zhSyl(s) {
    s = s.replace(/ü/g, "v");
    let ini = "", fin = s;
    if (ZY[s]) fin = ZY[s];
    else {
      for (const k of ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r", "z", "c", "s"]) {
        if (s.startsWith(k)) { ini = k; fin = s.slice(k.length); break; }
      }
      if ("jqx".includes(ini) && fin.startsWith("u")) fin = "v" + fin.slice(1);
      if (fin === "ue") fin = "ve";
    }
    // zhi · chi · shi · ri · zi · ci · si 는 '으'
    const parts = (["zh", "ch", "sh", "r", "z", "c", "s"].includes(ini) && fin === "i") ? [["eu"]] : ZF[fin];
    if (!parts) return s;
    return parts.map((p, k) => syl(k === 0 ? (ZI[ini] ?? "") : "", p[0], p[1] || "")).join("");
  }
  // 병음은 붙어 있을 수도 있어서(wǒài) 음절로 자름
  function zhWord(w) {
    const out = [];
    let i = 0;
    const all = [...Object.keys(ZY), ...Object.keys(ZF)];
    while (i < w.length) {
      let best = "";
      for (let len = Math.min(6, w.length - i); len > 0; len--) {
        const piece = w.slice(i, i + len);
        if (ZY[piece] || zhValid(piece)) { best = piece; break; }
      }
      if (!best) { i++; continue; }
      out.push(zhSyl(best));
      i += best.length;
    }
    return out.join("");
    function zhValid(p) {
      for (const k of ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r", "z", "c", "s", ""]) {
        if (p.startsWith(k)) { const f = p.slice(k.length); if (ZF[f] || (f === "ue")) return true; }
      }
      return all.includes(p);
    }
  }

  /// lang: 번역 서비스가 알아낸 원문 언어 (ja · zh-CN · zh-TW …), roman: 그 줄의 로마자
  function hangul(roman, lang) {
    if (!roman) return "";
    // 줄마다 다시 판단: 병음은 성조 표시(ǎ à á …)가 있고, 일본어 로마자는 장음 표시(ā ō)만 씀
    const toned = /[ǎěǐǒǔǚàèìòùǜáéíóúǘ]/i.test(roman);
    const zh = String(lang || "").startsWith("zh") || toned;
    const ja = !zh && String(lang || "").startsWith("ja");
    if (!zh && !ja) return "";
    const src = zh ? roman.replace(/ü/gi, "v") : roman;
    return deaccent(src).toLowerCase().replace(/[a-z']+/g, (w) => (zh ? zhWord(w.replace(/'/g, "")) : jaWord(w)));
  }
  return { hangul };
})();
