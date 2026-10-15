classdef Access
    % Access
    %
    % Engineering-mode password.
    %
    % Two passwords unlock Engineering mode:
    %
    %   Station password   set from Settings, stored in the user's
    %                      settings.json as a salted hash only
    %   Master password    hash in resources/engineering_master.json
    %                      (in the repo and compiled into CATS.exe)
    %
    % Only PBKDF2-SHA256 hashes are stored, never the passwords. Deleting
    % or editing the station entry in settings.json does not unlock
    % anything: the master password is then the only way in. If no
    % master hash exists, Engineering mode cannot be unlocked at all.
    %
    % Set or replace the master password (then commit the file):
    %
    %   CATS.Access.setMasterPassword()
    %
    % If the master password is forgotten, run setMasterPassword again,
    % commit, and rebuild CATS.exe.
    %

    properties (Constant)

        Iterations = 100000

    end

    methods (Static)

        function [ok, which] = check(password, settings)
            % True if the password matches the station or master password.
            % which: "station" | "master" | ""

            ok = false;
            which = "";

            if strlength(password) == 0
                return
            end

            if CATS.Access.matches(password, settings.EngineeringPassword)
                ok = true;
                which = "station";
            elseif CATS.Access.matches(password, CATS.Access.masterRecord())
                ok = true;
                which = "master";
            end

        end

        function tf = isConfigured(settings)
            % True if any password can unlock Engineering mode.

            tf = CATS.Access.isValidRecord(settings.EngineeringPassword) || ...
                CATS.Access.isValidRecord(CATS.Access.masterRecord());

        end

        function rec = makeRecord(password)
            % Salted hash record for a password.

            salt = randi([0 255], 1, 16, 'uint8');

            rec = struct( ...
                'Salt', lower(reshape(dec2hex(salt, 2).', 1, [])), ...
                'Hash', CATS.Access.hash(password, salt, CATS.Access.Iterations), ...
                'Iterations', CATS.Access.Iterations);

        end

        function tf = matches(password, rec)

            tf = false;

            if ~CATS.Access.isValidRecord(rec)
                return
            end

            salt = uint8(hex2dec(reshape(char(rec.Salt), 2, []).')).';

            tf = strcmp(CATS.Access.hash(password, salt, rec.Iterations), rec.Hash);

        end

        function rec = masterRecord()
            % Master hash shipped with the app ([] if none).

            rec = [];

            file = CATS.Access.masterFile();

            if isfile(file)
                try
                    rec = jsondecode(fileread(file));
                catch
                    rec = [];
                end
            end

        end

        function file = masterFile()

            root = fileparts(fileparts(mfilename('fullpath')));

            file = fullfile(root, 'resources', 'engineering_master.json');

        end

        function setMasterPassword()
            % Ask for a new master password (twice, masked) and write its
            % hash to resources/engineering_master.json. Commit that file.

            password = CATS.Access.prompt('Master Password', ...
                'New engineering master password:');

            if strlength(password) == 0
                disp('Cancelled; master password not changed.');
                return
            end

            again = CATS.Access.prompt('Master Password', 'Type it again:');

            if ~strcmp(password, again)
                disp('The passwords did not match; master password not changed.');
                return
            end

            rec = CATS.Access.makeRecord(password);

            file = CATS.Access.masterFile();

            fid = fopen(file, 'w');
            fprintf(fid, '%s', jsonencode(rec, PrettyPrint=true));
            fclose(fid);

            fprintf('Master password hash written to %s\nCommit this file.\n', file);

        end

        function password = prompt(title, message, theme, parent)
            % Modal dialog with a masked password box. "" if cancelled.

            arguments
                title {mustBeTextScalar}
                message {mustBeTextScalar}
                theme {mustBeTextScalar} = "light"
                parent = []
            end

            password = "";

            d = uifigure('Name', title, 'Position', [400 400 520 190], ...
                'WindowStyle', 'modal', 'Theme', theme, 'Tag', 'CATS_PasswordDialog');

            if ~isempty(parent) && isvalid(parent)
                d.Position(1:2) = parent.Position(1:2) + ...
                    (parent.Position(3:4) - d.Position(3:4))/2;
            end

            g = uigridlayout(d, [3 3]);
            g.RowHeight = {'fit', 40, 40};
            g.ColumnWidth = {'1x', 110, 110};

            l = uilabel(g, 'Text', message, 'FontSize', CATS.Theme.FontBase, 'WordWrap', 'on');
            l.Layout.Column = [1 3];

            % Text field that shows one bullet per character; the real
            % text is kept in "typed" as it changes
            field = uieditfield(g, 'text', 'FontSize', CATS.Theme.FontLarge, ...
                'Tag', 'CATS_PasswordField', 'ValueChangingFcn', @onChanging);
            field.Layout.Column = [1 3];

            ok = uibutton(g, 'Text', 'OK', 'FontSize', CATS.Theme.FontBase, ...
                'ButtonPushedFcn', @(~,~) uiresume(d));
            ok.Layout.Row = 3;
            ok.Layout.Column = 2;
            CATS.Theme.style(ok, "primary");

            cancel = uibutton(g, 'Text', 'Cancel', 'FontSize', CATS.Theme.FontBase, ...
                'ButtonPushedFcn', @(~,~) delete(d));
            cancel.Layout.Row = 3;
            cancel.Layout.Column = 3;

            typed = "";

            focus(field);

            uiwait(d);

            if isvalid(d)
                password = typed;
                delete(d);
            end

            function onChanging(src, event)
                typed = CATS.Access.unmask(typed, string(event.Value));
                src.Value = repmat(char(8226), 1, strlength(typed));
            end

        end

    end

    methods (Static, Access = private)

        function hex = hash(password, salt, iterations)

            factory = javax.crypto.SecretKeyFactory.getInstance('PBKDF2WithHmacSHA256');

            spec = javax.crypto.spec.PBEKeySpec( ...
                java.lang.String(char(password)).toCharArray(), ...
                typecast(uint8(salt), 'int8'), int32(iterations), int32(256));

            key = typecast(factory.generateSecret(spec).getEncoded(), 'uint8');

            spec.clearPassword();

            hex = lower(reshape(dec2hex(key, 2).', 1, []));

        end

        function tf = isValidRecord(rec)

            tf = isstruct(rec) && isscalar(rec) && ...
                all(isfield(rec, {'Salt','Hash','Iterations'})) && ...
                strlength(string(rec.Hash)) == 64 && strlength(string(rec.Salt)) == 32;

        end

    end

    methods (Static, Hidden)

        function typed = unmask(typed, shown)
            % New real text from a masked field's displayed text: the
            % bullets are characters already typed, anything else is new.
            % Deletions drop characters from the end.

            bullet = char(8226);

            kept = count(shown, bullet);

            typed = extractBefore(typed, min(kept, strlength(typed)) + 1) + erase(shown, bullet);

        end

    end

end
