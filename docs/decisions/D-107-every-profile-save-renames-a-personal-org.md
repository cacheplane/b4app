## 2026-11-02 (sign-in build)

- **D-107 Every profile save renames a personal org after the first name.** `accounts::set_profile`. Onboarding and a later name change in Settings → Account both call `PUT /v1/me/profile`, which names a personal org the user owns "<first word>'s Org" ("My Org" when that is empty); a shared org keeps its name. The page says so under the field ("Your org is named after your first name."). Naming the org otherwise is not offered.
