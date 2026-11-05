/// 表结构迁移。版本号保存在 `PRAGMA user_version`。
///
/// 规则：
/// - 只追加新的迁移，不修改已发布的迁移；
/// - 每个迁移在一个事务里执行，失败整体回滚，版本号不变；
/// - 每次修改表结构都要在 `DatabaseTests` 里补迁移测试。
public enum Migrations {
    public static let latestVersion = 12

    static let steps: [(version: Int, sql: String)] = [
        (1, """
        CREATE TABLE accounts (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            bank_id TEXT,
            bank_name TEXT NOT NULL,
            last4 TEXT NOT NULL CHECK (length(last4) = 4 AND last4 GLOB '[0-9][0-9][0-9][0-9]'),
            card_type TEXT NOT NULL,
            currency TEXT NOT NULL,
            palette_id TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            created_at REAL NOT NULL,
            archived INTEGER NOT NULL DEFAULT 0,
            last_success_at REAL,
            last_success_source TEXT,
            received_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX accounts_last4 ON accounts(last4);

        CREATE TABLE ingests (
            id TEXT PRIMARY KEY NOT NULL,
            fingerprint TEXT NOT NULL UNIQUE,
            source TEXT NOT NULL,
            sender TEXT,
            subject TEXT,
            received_at REAL,
            message_id TEXT,
            bound_account_id TEXT,
            processed_at REAL NOT NULL,
            raw_text TEXT,
            raw_purge_after REAL,
            classification TEXT NOT NULL,
            outcome TEXT NOT NULL,
            detail TEXT NOT NULL DEFAULT '',
            parser_version INTEGER NOT NULL
        );
        CREATE INDEX ingests_processed ON ingests(processed_at DESC);

        CREATE TABLE records (
            id TEXT PRIMARY KEY NOT NULL,
            account_id TEXT NOT NULL REFERENCES accounts(id),
            amount_minor INTEGER NOT NULL CHECK (amount_minor >= 0),
            currency TEXT NOT NULL,
            direction TEXT NOT NULL CHECK (direction IN ('inflow', 'outflow')),
            kind TEXT NOT NULL,
            status TEXT NOT NULL,
            counterparty TEXT,
            txn_time TEXT,
            txn_year_inferred INTEGER NOT NULL DEFAULT 0,
            received_at REAL,
            processed_at REAL NOT NULL,
            effective_at REAL NOT NULL,
            source TEXT NOT NULL,
            ingest_id TEXT NOT NULL REFERENCES ingests(id),
            part_index INTEGER NOT NULL,
            bank_reference TEXT,
            balance_after_minor INTEGER,
            included_fee_minor INTEGER,
            note TEXT NOT NULL DEFAULT '',
            transfer_group TEXT,
            related_record_id TEXT,
            dedupe_key TEXT NOT NULL UNIQUE,
            created_at REAL NOT NULL
        );
        CREATE INDEX records_effective ON records(effective_at DESC, id DESC);
        CREATE INDEX records_account ON records(account_id, effective_at DESC, id DESC);
        CREATE INDEX records_match ON records(amount_minor, currency, direction);

        CREATE TABLE record_evidence (
            record_id TEXT NOT NULL REFERENCES records(id),
            ingest_id TEXT NOT NULL REFERENCES ingests(id),
            source TEXT NOT NULL,
            added_at REAL NOT NULL,
            PRIMARY KEY (record_id, ingest_id)
        );

        CREATE TABLE balance_observations (
            id TEXT PRIMARY KEY NOT NULL,
            account_id TEXT NOT NULL REFERENCES accounts(id),
            amount_minor INTEGER NOT NULL,
            currency TEXT NOT NULL,
            order_key TEXT NOT NULL,
            txn_time TEXT,
            observed_at REAL NOT NULL,
            ingest_id TEXT NOT NULL REFERENCES ingests(id),
            record_id TEXT
        );
        CREATE INDEX balance_account ON balance_observations(account_id, order_key DESC);

        CREATE TABLE pending_items (
            id TEXT PRIMARY KEY NOT NULL,
            ingest_id TEXT NOT NULL REFERENCES ingests(id),
            part_index INTEGER NOT NULL,
            reason TEXT NOT NULL,
            draft_json TEXT,
            candidate_account_ids TEXT NOT NULL DEFAULT '',
            duplicate_of_record_id TEXT,
            status TEXT NOT NULL DEFAULT 'open',
            created_at REAL NOT NULL,
            resolved_at REAL,
            UNIQUE (ingest_id, part_index)
        );
        CREATE INDEX pending_status ON pending_items(status, created_at DESC);

        CREATE TABLE settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """),
        // 用户填写的初始余额：没有银行通知余额时作为推算余额的起点
        (2, """
        ALTER TABLE accounts ADD COLUMN opening_balance_minor INTEGER;
        ALTER TABLE accounts ADD COLUMN opening_balance_at REAL;
        """),
        // 选填的完整卡号；卡面背景图（文件标识）与文字颜色、大小
        (3, """
        ALTER TABLE accounts ADD COLUMN card_number TEXT;
        ALTER TABLE accounts ADD COLUMN face_image_id TEXT;
        ALTER TABLE accounts ADD COLUMN face_text_color INTEGER;
        ALTER TABLE accounts ADD COLUMN face_text_scale REAL NOT NULL DEFAULT 1;
        """),
        // 多币种账户：其他币种；初始余额改为按币种保存（迁入原来主币种的初始余额，旧的两列不再使用）
        (4, """
        ALTER TABLE accounts ADD COLUMN extra_currencies TEXT NOT NULL DEFAULT '';
        CREATE TABLE opening_balances (
            account_id TEXT NOT NULL REFERENCES accounts(id),
            currency TEXT NOT NULL,
            amount_minor INTEGER NOT NULL,
            set_at REAL NOT NULL,
            PRIMARY KEY (account_id, currency)
        );
        INSERT INTO opening_balances (account_id, currency, amount_minor, set_at)
            SELECT id, currency, opening_balance_minor, COALESCE(opening_balance_at, created_at)
            FROM accounts WHERE opening_balance_minor IS NOT NULL;
        UPDATE accounts SET opening_balance_minor = NULL, opening_balance_at = NULL;
        """),
        // 选填的账号（户口号码，可打码）：只写账号的银行通知靠它匹配到卡；
        // 没配对到自己另一张卡的转账，用户确认的对方（own / other，NULL 为未确认）
        (5, """
        ALTER TABLE accounts ADD COLUMN account_number TEXT;
        ALTER TABLE records ADD COLUMN transfer_party TEXT;
        """),
        // 用户在本机做的识别模板：只保存写法（文字 + 占位），不保存原文里的数字
        (6, """
        CREATE TABLE message_templates (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            pieces_json TEXT NOT NULL,
            kind TEXT NOT NULL,
            direction TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """),
        // 账户不持有的币种的交易按主币种扣款：用户填写的实际扣款（为空时按当天汇率估算）；
        // 每天的完整汇率表（快捷指令导入），按交易当天的汇率估算扣款
        (7, """
        ALTER TABLE records ADD COLUMN settlement_minor INTEGER;
        ALTER TABLE records ADD COLUMN settlement_currency TEXT;
        CREATE TABLE exchange_rate_days (
            day TEXT PRIMARY KEY NOT NULL,
            base TEXT NOT NULL,
            updated_at REAL NOT NULL,
            fetched_at REAL NOT NULL
        );
        CREATE TABLE exchange_rates (
            day TEXT NOT NULL REFERENCES exchange_rate_days(day),
            currency TEXT NOT NULL,
            rate REAL NOT NULL,
            PRIMARY KEY (day, currency)
        );
        """),
        // 参考 MOZE 的基础记账：用户自己定的分类（最多两层，默认一套只是起点）；流水的分类、合成一单；
        // 按交易对方记住的分类（`kind|对方`，kind 为 expense / income / own）。
        // 已有流水里能直接归类的（手续费、扣息、工资、利息）补上分类，其余是待分类
        (8, """
        CREATE TABLE categories (
            id TEXT PRIMARY KEY NOT NULL,
            type TEXT NOT NULL CHECK (type IN ('expense', 'income', 'transfer')),
            parent_id TEXT REFERENCES categories(id),
            name TEXT NOT NULL,
            symbol TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            hidden INTEGER NOT NULL DEFAULT 0,
            auto_key TEXT UNIQUE,
            locked INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        );
        CREATE INDEX categories_parent ON categories(type, parent_id, sort_order);
        \(defaultCategoriesSQL)
        ALTER TABLE records ADD COLUMN category_id TEXT;
        ALTER TABLE records ADD COLUMN order_group TEXT;
        CREATE INDEX records_category ON records(category_id);
        CREATE INDEX records_ingest ON records(ingest_id, part_index);
        CREATE INDEX records_related ON records(related_record_id);
        CREATE INDEX records_transfer_group ON records(transfer_group);
        CREATE INDEX records_order_group ON records(order_group);
        CREATE TABLE counterparty_rules (
            key TEXT PRIMARY KEY NOT NULL,
            category_id TEXT,
            updated_at REAL NOT NULL
        );
        UPDATE records SET category_id = 'sys.fee' WHERE kind = 'fee' AND direction = 'outflow';
        UPDATE records SET category_id = 'sys.interest' WHERE kind = 'interestCharge' AND direction = 'outflow';
        UPDATE records SET category_id = 'in.salary' WHERE kind = 'salary' AND direction = 'inflow';
        UPDATE records SET category_id = 'in.interest' WHERE kind = 'interestIncome' AND direction = 'inflow';
        """),
        // 删除账户只做标记：流水留着，账户名称后面写「已删除」
        (9, """
        ALTER TABLE accounts ADD COLUMN deleted_at REAL;
        """),
        // 卡面用图片时金额的描边颜色和位置（默认右上角）
        (10, """
        ALTER TABLE accounts ADD COLUMN face_outline_color INTEGER;
        ALTER TABLE accounts ADD COLUMN face_amount_x REAL NOT NULL DEFAULT 1;
        ALTER TABLE accounts ADD COLUMN face_amount_y REAL NOT NULL DEFAULT 0;
        """),
        // 学习归类（ADR 0017）：一个商户选过哪些分类（`merchant` 是「类型|归一化的商户」，`picks` 一共选过几次，
        // `streak` 连续选了几次，只有最近选的那个分类不是 0）；流水记下分类是不是自动归的。
        // `counterparty_rules` 一个键只能存一个分类，也早就不读写了，删掉
        (11, """
        ALTER TABLE records ADD COLUMN category_auto INTEGER NOT NULL DEFAULT 0;
        DROP TABLE counterparty_rules;
        CREATE TABLE merchant_categories (
            merchant TEXT NOT NULL,
            category_id TEXT NOT NULL,
            picks INTEGER NOT NULL,
            streak INTEGER NOT NULL,
            last_picked_at REAL NOT NULL,
            PRIMARY KEY (merchant, category_id)
        );
        CREATE INDEX merchant_categories_category ON merchant_categories(category_id);
        """),
        // 一笔支出和另一个账户的一笔收入手动合成转帐（ADR 0014 修订 2026-11-05）：记下合成前的交易性质、对方、分类，
        // 拆开时改回去。`merged_kind` 不为空就是合成的
        (12, """
        ALTER TABLE records ADD COLUMN merged_kind TEXT;
        ALTER TABLE records ADD COLUMN merged_party TEXT;
        ALTER TABLE records ADD COLUMN merged_category_id TEXT;
        ALTER TABLE records ADD COLUMN merged_category_auto INTEGER NOT NULL DEFAULT 0;
        """),
    ]

    /// 第一次打开时的默认分类（迁移 8 写入，之后不再改这里）。
    /// 支出两层、收入一层；手续费、扣息是系统分类，转帐的三个分类按交易性质自动对应，这些都不能删除
    static let defaultCategoriesSQL: String = {
        // (id, type, parent, name, symbol, autoKey, locked)
        let seeds: [(String, String, String?, String, String, String?, Bool)] = [
            ("ex.food", "expense", nil, "饮食", "fork.knife", "food", false),
            ("ex.food.breakfast", "expense", "ex.food", "早餐", "sunrise", "food.breakfast", false),
            ("ex.food.lunch", "expense", "ex.food", "午餐", "sun.max", "food.lunch", false),
            ("ex.food.dinner", "expense", "ex.food", "晚餐", "moon.stars", "food.dinner", false),
            ("ex.food.snack", "expense", "ex.food", "饮料零食", "cup.and.saucer", nil, false),
            ("ex.clothes", "expense", nil, "衣着", "tshirt", nil, false),
            ("ex.clothes.wear", "expense", "ex.clothes", "服装", "tshirt", nil, false),
            ("ex.clothes.bag", "expense", "ex.clothes", "鞋包", "bag", nil, false),
            ("ex.home", "expense", nil, "居住", "house", nil, false),
            ("ex.home.rent", "expense", "ex.home", "房租", "key", nil, false),
            ("ex.home.utility", "expense", "ex.home", "水电燃气", "bolt", nil, false),
            ("ex.home.phone", "expense", "ex.home", "话费网费", "wifi", nil, false),
            ("ex.traffic", "expense", nil, "交通", "car", nil, false),
            ("ex.traffic.transit", "expense", "ex.traffic", "公交地铁", "tram.fill", nil, false),
            ("ex.traffic.taxi", "expense", "ex.traffic", "打车", "car.fill", nil, false),
            ("ex.traffic.fuel", "expense", "ex.traffic", "加油停车", "fuelpump", nil, false),
            ("ex.traffic.trip", "expense", "ex.traffic", "火车飞机", "airplane", nil, false),
            ("ex.study", "expense", nil, "学习", "graduationcap", nil, false),
            ("ex.study.book", "expense", "ex.study", "书", "book.closed", nil, false),
            ("ex.study.course", "expense", "ex.study", "课程", "pencil", nil, false),
            ("ex.fun", "expense", nil, "娱乐", "gamecontroller", nil, false),
            ("ex.fun.media", "expense", "ex.fun", "游戏电影", "film", nil, false),
            ("ex.fun.travel", "expense", "ex.fun", "旅游", "suitcase", nil, false),
            ("ex.fun.sport", "expense", "ex.fun", "运动", "figure.run", nil, false),
            ("ex.daily", "expense", nil, "日用品", "basket", nil, false),
            ("ex.medical", "expense", nil, "医疗", "cross.case", nil, false),
            ("ex.gift", "expense", nil, "人情", "gift", nil, false),
            ("ex.gift.redpacket", "expense", "ex.gift", "红包", "envelope", nil, false),
            ("ex.gift.present", "expense", "ex.gift", "礼物", "gift", nil, false),
            ("ex.gift.treat", "expense", "ex.gift", "请客", "person.2", nil, false),
            ("ex.other", "expense", nil, "其他", "ellipsis.circle", nil, false),
            ("sys.fee", "expense", nil, "手续费", "doc.text", "fee", true),
            ("sys.interest", "expense", nil, "扣息", "percent", "interest", true),
            ("in.salary", "income", nil, "工资", "briefcase", "salary", false),
            ("in.bonus", "income", nil, "奖金", "star", nil, false),
            ("in.interest", "income", nil, "利息理财", "chart.line.uptrend.xyaxis", "interestIncome", false),
            ("in.gift", "income", nil, "红包和转来的钱", "envelope", nil, false),
            ("in.other", "income", nil, "其他", "ellipsis.circle", nil, false),
            ("tr.own", "transfer", nil, "转帐", "arrow.left.arrow.right", "transfer.own", true),
            ("tr.repayment", "transfer", nil, "还信用卡", "creditcard", "transfer.repayment", true),
            ("tr.cash", "transfer", nil, "存取现金", "banknote", "transfer.cash", true),
        ]
        var order: [String: Int] = [:]
        return seeds.map { id, type, parent, name, symbol, autoKey, locked in
            let group = type + "|" + (parent ?? "")
            let sort = order[group, default: 0]
            order[group] = sort + 1
            let values = [
                "'\(id)'", "'\(type)'", parent.map { "'\($0)'" } ?? "NULL", "'\(name)'", "'\(symbol)'", String(sort),
                autoKey.map { "'\($0)'" } ?? "NULL", locked ? "1" : "0",
            ]
            return "INSERT INTO categories (id, type, parent_id, name, symbol, sort_order, auto_key, locked, created_at) VALUES (\(values.joined(separator: ", ")), 0);"
        }.joined(separator: "\n")
    }()

    public static func migrate(_ connection: SQLiteConnection) throws {
        let current = connection.userVersion
        guard current < latestVersion else { return }
        for step in steps where step.version > current {
            try connection.immediateTransaction {
                try connection.execute(step.sql)
                try connection.setUserVersion(step.version)
            }
        }
    }
}
