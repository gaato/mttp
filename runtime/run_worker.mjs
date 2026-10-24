const mod = await import(process.argv[2]);
console.log('exports:', Object.keys(mod), typeof mod.fetch);
if (typeof mod.fetch === 'function') {
  const r = await mod.fetch(new Request('http://w.test/x'));
  console.log(r.status, await r.text());
}
