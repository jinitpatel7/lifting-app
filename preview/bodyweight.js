import { dayDistance } from './schedule.js';

export function bodyweightTrend(entries, through) {
  const ordered = [...entries].filter(entry => !through || entry.day <= through).sort((a, b) => a.day.localeCompare(b.day));
  let start = 0;
  return ordered.map((entry, index) => {
    while (dayDistance(ordered[start].day, entry.day) >= 7) start++;
    const count = index - start + 1;
    const smoothed = count >= 2 ? ordered.slice(start, index + 1).reduce((total, value) => total + value.kilograms / count, 0) : null;
    return { ...entry, smoothed };
  });
}
