function commitProfile() {
  const code = document.getElementById('operator-code').value || 'empty';
  const survey = document.getElementById('survey-mode').checked ? 'survey_on' : 'survey_off';
  const fruit = document.body.dataset.favoriteFruit || 'Choose a Fruit';
  const page = document.body.dataset.pageIndex || 'unknown';
  document.body.dataset.profileSaved = 'true';
  document.getElementById('profile-status').textContent = `profile_saved:${page}:${code}:${survey}:${fruit}`;
}

function toggleFruitList() {
  selectFruit('Banana');
}

function selectFruit(value) {
  document.body.dataset.favoriteFruit = value;
  const list = document.querySelector('.combo-options');
  const trigger = document.querySelector('.combo-trigger');
  trigger.textContent = `Favorite Fruit: ${value}`;
  trigger.setAttribute('aria-expanded', 'false');
  list.hidden = true;
}

window.addEventListener('DOMContentLoaded', () => {
  const checkbox = document.getElementById('survey-mode');
  if (checkbox) {
    checkbox.addEventListener('change', () => {
      if (checkbox.checked) {
        selectFruit('Banana');
      }
    });
  }
});
