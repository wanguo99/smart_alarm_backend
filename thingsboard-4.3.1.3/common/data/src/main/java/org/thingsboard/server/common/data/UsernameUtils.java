/**
 * Copyright © 2016-2026 The Thingsboard Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.thingsboard.server.common.data;

import java.util.Locale;
import java.util.regex.Pattern;

public final class UsernameUtils {

    public static final int MIN_LENGTH = 3;
    public static final int MAX_LENGTH = 64;

    private static final Pattern USERNAME_PATTERN = Pattern.compile(
            "^(?:[a-z0-9][a-z0-9._@-]{1,62}[a-z0-9]|\\+[0-9]{3,63})$");

    private UsernameUtils() {
    }

    public static String normalize(String username) {
        return username == null ? null : username.trim().toLowerCase(Locale.ROOT);
    }

    public static boolean isValid(String username) {
        return username != null
                && username.length() >= MIN_LENGTH
                && username.length() <= MAX_LENGTH
                && USERNAME_PATTERN.matcher(username).matches();
    }

}
