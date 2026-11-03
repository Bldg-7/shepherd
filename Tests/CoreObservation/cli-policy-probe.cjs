// Nonsecret synthetic files only. Do not point this at user configuration.
const fs = require('node:fs');
const [present, missing, alias] = process.argv.slice(2);
const result = {};
for (const [name, path] of [['present', present], ['missing', missing], ['alias', alias]]) {
  try { fs.readFileSync(path); result[name] = 'UNEXPECTED_READ'; }
  catch (error) { result[name] = error.code; }
}
console.log(JSON.stringify(result));
process.exit(result.present === 'EPERM' && result.missing === 'ENOENT' && result.alias === 'EPERM' ? 0 : 1);
