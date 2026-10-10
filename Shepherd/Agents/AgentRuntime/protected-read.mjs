import fs from 'node:fs';

// Shared by browser MCP and credential CLI; never follows a capability symlink.
export function protectedRead(file) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const s = fs.fstatSync(fd);
    if (!s.isFile() || s.uid !== process.getuid() || (s.mode & 0o077) !== 0 || s.size > 1024 * 1024) throw new Error('unsafe-file');
    return fs.readFileSync(fd, 'utf8');
  } finally { fs.closeSync(fd); }
}
