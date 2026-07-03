
namespace {


} // namespace

int main() {
    auto xs = BallDyn(std::vector<int64_t>{static_cast<int64_t>(1), static_cast<int64_t>(2), static_cast<int64_t>(3), static_cast<int64_t>(4), static_cast<int64_t>(5)});
    auto product = BallDyn(static_cast<int64_t>(1));
    for (auto i = static_cast<int64_t>(0); (i < ball_length(xs)); ball_assign(i, (i + static_cast<int64_t>(1)))) {
        ball_assign(product, (product * static_cast<BallDyn>(xs)[i]));
    }
    std::cout << ball_to_string(ball_to_string(product)) << std::endl;
    auto total = BallDyn(static_cast<int64_t>(0));
    for (auto x : BallDyn(xs)) {
        ball_assign(total, (total + x));
    }
    std::cout << ball_to_string(ball_to_string(total)) << std::endl;
    return 0;
}
