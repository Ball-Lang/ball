
namespace {


} // namespace

int main() {
    auto sum = BallDyn(static_cast<int64_t>(0));
    for (auto i = static_cast<int64_t>(1); (i <= static_cast<int64_t>(3)); ball_assign(i, (i + static_cast<int64_t>(1)))) {
        for (auto j = static_cast<int64_t>(1); (j <= static_cast<int64_t>(3)); ball_assign(j, (j + static_cast<int64_t>(1)))) {
            if ((i == j)) {
                continue;
            }
            ball_assign(sum, (sum + (i * j)));
        }
    }
    std::cout << ball_to_string(ball_to_string(sum)) << std::endl;
    return 0;
}
