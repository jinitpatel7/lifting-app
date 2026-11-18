export const energySource = 'https://pacompendium.com/conditioning-exercise/';
export const energyReference = 'https://pmc.ncbi.nlm.nih.gov/articles/PMC10818145/';
export const energyActivities = Object.freeze({
  variedResistance: { title: 'Varied resistance, multiple exercises (8–15 reps)', code: '02054', met: 3.5 },
  vigorousLifting: { title: 'Vigorous lifting, powerlifting, or bodybuilding', code: '02050', met: 6 },
  squatDeadlift: { title: 'Squats and deadlifts, slow or explosive effort', code: '02052', met: 5 },
});

export function validEnergyInput(input) {
  return Boolean(input && Object.hasOwn(energyActivities, input.activity) && Number.isFinite(input.minutes) &&
    input.minutes > 0 && input.minutes <= 1440);
}

export function workoutEnergy(input, kilograms) {
  if (!validEnergyInput(input) || !Number.isFinite(kilograms) || kilograms <= 0) return null;
  const { met, code } = energyActivities[input.activity];
  const kilocalories = met * (input.minutes / 60) * kilograms;
  return Number.isFinite(kilocalories) ? { kilocalories, met, code, kilograms, minutes: input.minutes } : null;
}
